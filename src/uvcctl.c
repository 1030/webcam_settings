/*
 * uvcctl — read/write USB Video Class (UVC) camera controls on macOS.
 *
 * macOS has no UI for the color controls that live in a webcam's firmware
 * (white balance, saturation, gain, exposure...). They are reachable over
 * plain USB control transfers to the camera's VideoControl interface, which
 * is what this tool does via IOKit.
 *
 * Usage:
 *   uvcctl list                       list attached UVC cameras
 *   uvcctl caps [-d vid:pid]          JSON of every supported control
 *   uvcctl get  <control> [-d ...]    print one current value
 *   uvcctl set  <control> <value>     write one value
 *   uvcctl reset [-d ...]             restore every control to its default
 *
 * Build: cc -O2 -Wall -o uvcctl uvcctl.c -framework IOKit -framework CoreFoundation
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>

/* ---- UVC constants (UVC 1.5 spec, sections A.8 / 4.2) ------------------ */

#define UVC_SET_CUR 0x01
#define UVC_GET_CUR 0x81
#define UVC_GET_MIN 0x82
#define UVC_GET_MAX 0x83
#define UVC_GET_RES 0x84
#define UVC_GET_LEN 0x85
#define UVC_GET_INFO 0x86
#define UVC_GET_DEF 0x87

#define CC_VIDEO 0x0E
#define SC_VIDEOCONTROL 0x01
#define CS_INTERFACE 0x24
#define VC_INPUT_TERMINAL 0x02
#define VC_PROCESSING_UNIT 0x05
#define ITT_CAMERA 0x0201

/* GET_INFO bits */
#define INFO_GET_SUPPORTED 0x01
#define INFO_SET_SUPPORTED 0x02
#define INFO_AUTO_UPDATE 0x08

typedef enum { UNIT_PU, UNIT_CT } unit_kind;

typedef struct {
    const char *name;   /* stable machine name used by the CLI + web UI */
    const char *label;  /* human label */
    unit_kind unit;
    uint8_t selector;
    uint8_t len;        /* payload size in bytes */
    int is_signed;
    int bit;            /* bit index in the unit's bmControls bitmap */
    const char *kind;   /* range | bool | enum */
    const char *group;  /* color | exposure | image | lens */
} ctrl_t;

/*
 * bmControls bit assignments: UVC 1.5 tables 4-8 (camera terminal) and
 * 4-14 (processing unit). A control is only addressable if its bit is set.
 */
static const ctrl_t CONTROLS[] = {
    /* --- processing unit: the colour pipeline --- */
    {"white_balance_temperature", "White balance (K)", UNIT_PU, 0x0A, 2, 0, 6, "range", "color"},
    {"white_balance_temperature_auto", "Auto white balance", UNIT_PU, 0x0B, 1, 0, 12, "bool", "color"},
    {"saturation", "Saturation", UNIT_PU, 0x07, 2, 0, 3, "range", "color"},
    {"hue", "Hue", UNIT_PU, 0x06, 2, 1, 2, "range", "color"},
    {"hue_auto", "Auto hue", UNIT_PU, 0x10, 1, 0, 11, "bool", "color"},
    {"gamma", "Gamma", UNIT_PU, 0x09, 2, 0, 5, "range", "color"},
    {"brightness", "Brightness", UNIT_PU, 0x02, 2, 1, 0, "range", "image"},
    {"contrast", "Contrast", UNIT_PU, 0x03, 2, 0, 1, "range", "image"},
    {"contrast_auto", "Auto contrast", UNIT_PU, 0x13, 1, 0, 18, "bool", "image"},
    {"sharpness", "Sharpness", UNIT_PU, 0x08, 2, 0, 4, "range", "image"},
    {"gain", "Gain", UNIT_PU, 0x04, 2, 0, 9, "range", "exposure"},
    {"backlight_compensation", "Backlight compensation", UNIT_PU, 0x01, 2, 0, 8, "range", "exposure"},
    {"power_line_frequency", "Power line frequency", UNIT_PU, 0x05, 1, 0, 10, "enum", "exposure"},

    /* --- camera terminal: exposure + lens --- */
    {"exposure_auto", "Auto exposure mode", UNIT_CT, 0x02, 1, 0, 1, "enum", "exposure"},
    {"exposure_auto_priority", "Auto exposure priority", UNIT_CT, 0x03, 1, 0, 2, "bool", "exposure"},
    {"exposure_time_absolute", "Exposure time", UNIT_CT, 0x04, 4, 0, 3, "range", "exposure"},
    {"focus_absolute", "Focus", UNIT_CT, 0x06, 2, 0, 5, "range", "lens"},
    {"focus_auto", "Auto focus", UNIT_CT, 0x08, 1, 0, 17, "bool", "lens"},
    {"zoom_absolute", "Zoom", UNIT_CT, 0x0B, 2, 0, 9, "range", "lens"},
    /* Firmware privacy shutter, if the camera implements it: a real stop-capturing
     * switch rather than a black frame. Rare on cheap webcams. */
    {"privacy", "Privacy (camera off)", UNIT_CT, 0x11, 1, 0, 18, "bool", "privacy"},
};
static const int NCONTROLS = (int)(sizeof(CONTROLS) / sizeof(CONTROLS[0]));

/* ---- device handle ----------------------------------------------------- */

typedef struct {
    IOUSBDeviceInterface500 **dev;
    uint16_t vid, pid;
    uint32_t location;
    char name[128];
    char serial[128];
    uint8_t vc_interface;  /* bInterfaceNumber of the VideoControl interface */
    uint8_t pu_id;         /* processing unit ID, 0 = absent */
    uint8_t ct_id;         /* camera terminal ID, 0 = absent */
    uint8_t pu_bm[8];
    uint8_t ct_bm[8];
    int pu_bm_len, ct_bm_len;
    int opened;
} cam_t;

/* --force probes a control even when the descriptor does not advertise it. */
static int g_force = 0;

static int bm_has(const uint8_t *bm, int bmlen, int bit)
{
    int byte = bit / 8;
    if (byte >= bmlen) return 0;
    return (bm[byte] >> (bit % 8)) & 1;
}

static int ctrl_supported(const cam_t *c, const ctrl_t *k)
{
    if (g_force) return 1;
    if (k->unit == UNIT_PU)
        return c->pu_id && bm_has(c->pu_bm, c->pu_bm_len, k->bit);
    return c->ct_id && bm_has(c->ct_bm, c->ct_bm_len, k->bit);
}

/*
 * Walk the configuration descriptor to find the VideoControl interface and
 * the unit IDs / control bitmaps inside its class-specific descriptors.
 */
static int parse_vc(cam_t *c)
{
    IOUSBConfigurationDescriptorPtr cfg = NULL;
    if ((*c->dev)->GetConfigurationDescriptorPtr(c->dev, 0, &cfg) != kIOReturnSuccess || !cfg)
        return 0;

    const uint8_t *p = (const uint8_t *)cfg;
    int total = USBToHostWord(cfg->wTotalLength);
    int off = 0, in_vc = 0, found = 0;

    while (off + 2 <= total) {
        int len = p[off];
        int type = p[off + 1];
        if (len < 2) break;

        if (type == 0x04 /* interface */ && off + 9 <= total) {
            int cls = p[off + 5], sub = p[off + 6];
            in_vc = (cls == CC_VIDEO && sub == SC_VIDEOCONTROL);
            if (in_vc) {
                c->vc_interface = p[off + 2];
                found = 1;
            }
        } else if (in_vc && type == CS_INTERFACE && len >= 3) {
            int sub = p[off + 2];
            if (sub == VC_INPUT_TERMINAL && len >= 8) {
                int term_type = p[off + 4] | (p[off + 5] << 8);
                if (term_type == ITT_CAMERA && len >= 15) {
                    c->ct_id = p[off + 3];
                    int sz = p[off + 14];
                    if (sz > 8) sz = 8;
                    if (off + 15 + sz <= total) {
                        memcpy(c->ct_bm, p + off + 15, sz);
                        c->ct_bm_len = sz;
                    }
                }
            } else if (sub == VC_PROCESSING_UNIT && len >= 8) {
                c->pu_id = p[off + 3];
                int sz = p[off + 7];
                if (sz > 8) sz = 8;
                if (off + 8 + sz <= total) {
                    memcpy(c->pu_bm, p + off + 8, sz);
                    c->pu_bm_len = sz;
                }
            }
        }
        off += len;
    }
    return found;
}

static void get_string_prop(io_service_t svc, const char *key, char *out, size_t outsz)
{
    out[0] = '\0';
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(svc, k, kCFAllocatorDefault, 0);
    CFRelease(k);
    if (v) {
        if (CFGetTypeID(v) == CFStringGetTypeID())
            CFStringGetCString((CFStringRef)v, out, (CFIndex)outsz, kCFStringEncodingUTF8);
        CFRelease(v);
    }
}

static uint32_t get_location(io_service_t svc)
{
    uint32_t location = 0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(svc, CFSTR("locationID"), kCFAllocatorDefault, 0);
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &location);
        CFRelease(value);
    }
    return location;
}

/* Find UVC cameras. If want_vid is non-zero, only that vid:pid is returned. */
static int find_cameras(cam_t *out, int max, uint16_t want_vid, uint16_t want_pid,
                        uint32_t want_location)
{
    static const char *classes[] = {"IOUSBHostDevice", "IOUSBDevice"};
    int n = 0;

    for (int ci = 0; ci < 2 && n == 0; ci++) {
        CFMutableDictionaryRef match = IOServiceMatching(classes[ci]);
        if (!match) continue;
        io_iterator_t it = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS)
            continue;

        io_service_t svc;
        while ((svc = IOIteratorNext(it)) && n < max) {
            IOCFPlugInInterface **plug = NULL;
            SInt32 score = 0;
            if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                 kIOCFPlugInInterfaceID, &plug,
                                                 &score) != kIOReturnSuccess || !plug) {
                IOObjectRelease(svc);
                continue;
            }

            IOUSBDeviceInterface500 **dev = NULL;
            HRESULT hr = (*plug)->QueryInterface(
                plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500), (LPVOID *)&dev);
            IODestroyPlugInInterface(plug);
            if (hr != 0 || !dev) {
                IOObjectRelease(svc);
                continue;
            }

            cam_t c;
            memset(&c, 0, sizeof(c));
            c.dev = dev;
            (*dev)->GetDeviceVendor(dev, &c.vid);
            (*dev)->GetDeviceProduct(dev, &c.pid);
            c.location = get_location(svc);

            int keep = 0;
            if (parse_vc(&c) && (c.pu_id || c.ct_id)) {
                if ((!want_vid || (c.vid == want_vid && c.pid == want_pid)) &&
                    (!want_location || c.location == want_location)) {
                    get_string_prop(svc, "USB Product Name", c.name, sizeof(c.name));
                    get_string_prop(svc, "USB Serial Number", c.serial, sizeof(c.serial));
                    if (!c.name[0]) snprintf(c.name, sizeof(c.name), "USB camera %04x:%04x", c.vid, c.pid);
                    out[n++] = c;
                    keep = 1;
                }
            }
            if (!keep) (*dev)->Release(dev);
            IOObjectRelease(svc);
        }
        IOObjectRelease(it);
    }
    return n;
}

static int cam_open(cam_t *c)
{
    if (c->opened) return 1;
    IOReturn kr = (*c->dev)->USBDeviceOpen(c->dev);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "uvcctl: cannot open USB device (0x%08x)\n", kr);
        return 0;
    }
    c->opened = 1;
    return 1;
}

static void cam_close(cam_t *c)
{
    if (c->opened) {
        (*c->dev)->USBDeviceClose(c->dev);
        c->opened = 0;
    }
}

/* One UVC control request. Returns 1 on success. */
static int uvc_req(cam_t *c, int in, uint8_t req, const ctrl_t *k, uint8_t *buf, int len)
{
    uint8_t unit_id = (k->unit == UNIT_PU) ? c->pu_id : c->ct_id;

    IOUSBDevRequestTO r;
    memset(&r, 0, sizeof(r));
    r.bmRequestType = USBmakebmRequestType(in ? kUSBIn : kUSBOut, kUSBClass, kUSBInterface);
    r.bRequest = req;
    r.wValue = (uint16_t)(k->selector << 8);
    r.wIndex = (uint16_t)((unit_id << 8) | c->vc_interface);
    r.pData = buf;
    r.wLength = (uint16_t)len;
    r.noDataTimeout = 1000;
    r.completionTimeout = 1000;

    IOReturn result = (*c->dev)->DeviceRequestTO(c->dev, &r);
    if (result != kIOReturnSuccess && getenv("UVCCTL_DEBUG"))
        fprintf(stderr, "uvcctl: %08x %s %s request 0x%02x failed: 0x%08x\n",
                c->location, k->name, in ? "read" : "write", req, result);
    return result == kIOReturnSuccess;
}

static long decode(const uint8_t *b, int len, int is_signed)
{
    unsigned long v = 0;
    for (int i = 0; i < len; i++) v |= ((unsigned long)b[i]) << (8 * i);
    if (is_signed) {
        if (len == 1 && (v & 0x80)) return (long)v - 0x100;
        if (len == 2 && (v & 0x8000)) return (long)v - 0x10000;
    }
    return (long)v;
}

static void encode(long v, uint8_t *b, int len)
{
    unsigned long u = (unsigned long)v;
    for (int i = 0; i < len; i++) b[i] = (uint8_t)((u >> (8 * i)) & 0xFF);
}

static int read_val(cam_t *c, const ctrl_t *k, uint8_t req, long *out)
{
    uint8_t buf[8] = {0};
    if (!uvc_req(c, 1, req, k, buf, k->len)) return 0;
    *out = decode(buf, k->len, k->is_signed);
    return 1;
}

static const ctrl_t *lookup(const char *name)
{
    for (int i = 0; i < NCONTROLS; i++)
        if (strcmp(CONTROLS[i].name, name) == 0) return &CONTROLS[i];
    return NULL;
}

static void json_escape(const char *s, char *out, size_t outsz)
{
    size_t o = 0;
    for (; *s && o + 2 < outsz; s++) {
        if (*s == '"' || *s == '\\') { out[o++] = '\\'; out[o++] = *s; }
        else if ((unsigned char)*s < 0x20) { continue; }
        else out[o++] = *s;
    }
    out[o] = '\0';
}

/* ---- commands ---------------------------------------------------------- */

static const char *bm_hex(const uint8_t *bm, int len)
{
    static char bufs[2][24];
    static int which = 0;
    char *out = bufs[which++ & 1];
    out[0] = '\0';
    for (int i = len - 1, o = 0; i >= 0 && o < 20; i--, o += 2)
        snprintf(out + o, 4, "%02x", bm[i]);
    return out;
}

static int cmd_list(void)
{
    cam_t cams[16];
    int n = find_cameras(cams, 16, 0, 0, 0);
    printf("[");
    for (int i = 0; i < n; i++) {
        char esc[256], serial[256];
        json_escape(cams[i].name, esc, sizeof(esc));
        json_escape(cams[i].serial, serial, sizeof(serial));
        printf("%s\n  {\"name\":\"%s\",\"vid\":%u,\"pid\":%u,\"id\":\"%04x:%04x\","
               "\"location\":\"%08x\",\"serial\":\"%s\","
               "\"vc_interface\":%u,\"processing_unit\":%u,\"camera_terminal\":%u,"
               "\"pu_controls\":\"%s\",\"ct_controls\":\"%s\"}",
               i ? "," : "", esc, cams[i].vid, cams[i].pid, cams[i].vid, cams[i].pid,
               cams[i].location, serial,
               cams[i].vc_interface, cams[i].pu_id, cams[i].ct_id,
               bm_hex(cams[i].pu_bm, cams[i].pu_bm_len),
               bm_hex(cams[i].ct_bm, cams[i].ct_bm_len));
        (*cams[i].dev)->Release(cams[i].dev);
    }
    printf("%s]\n", n ? "\n" : "");
    return n ? 0 : 1;
}

static int cmd_caps(cam_t *c)
{
    if (!cam_open(c)) return 2;

    char esc[256], serial[256];
    json_escape(c->name, esc, sizeof(esc));
    json_escape(c->serial, serial, sizeof(serial));
    printf("{\n  \"camera\": {\"name\":\"%s\",\"id\":\"%04x:%04x\",\"location\":\"%08x\",\"serial\":\"%s\"},\n  \"controls\": [",
           esc, c->vid, c->pid, c->location, serial);

    int first = 1, consecutive_failures = 0;
    for (int i = 0; i < NCONTROLS; i++) {
        const ctrl_t *k = &CONTROLS[i];
        if (!ctrl_supported(c, k)) continue;

        long info = 0, cur = 0;
        /* GET_INFO is 1 byte regardless of the control's payload size. */
        uint8_t ibuf[4] = {0};
        int have_info = uvc_req(c, 1, UVC_GET_INFO, k, ibuf, 1);
        info = ibuf[0];
        if (have_info && !(info & INFO_GET_SUPPORTED)) continue;
        if (!read_val(c, k, UVC_GET_CUR, &cur)) {
            /* A camera that times out on every request should not freeze the UI
             * for one timeout per advertised control. */
            if (++consecutive_failures >= 3) break;
            continue;
        }
        consecutive_failures = 0;

        long mn = 0, mx = 1, res = 1, def = cur;
        if (strcmp(k->kind, "range") == 0) {
            if (!read_val(c, k, UVC_GET_MIN, &mn)) mn = 0;
            if (!read_val(c, k, UVC_GET_MAX, &mx)) mx = 0;
            if (!read_val(c, k, UVC_GET_RES, &res) || res <= 0) res = 1;
        } else if (strcmp(k->kind, "enum") == 0) {
            /* For enum controls GET_RES is a bitmap of the modes the camera
             * actually implements, not a step size. */
            if (!read_val(c, k, UVC_GET_RES, &res)) res = 0;
            mn = 0;
            mx = 255;
        }
        read_val(c, k, UVC_GET_DEF, &def);

        printf("%s\n    {\"name\":\"%s\",\"label\":\"%s\",\"group\":\"%s\",\"kind\":\"%s\","
               "\"min\":%ld,\"max\":%ld,\"step\":%ld,\"default\":%ld,\"value\":%ld,"
               "\"writable\":%s}",
               first ? "" : ",", k->name, k->label, k->group, k->kind,
               mn, mx, res, def, cur,
               (!have_info || (info & INFO_SET_SUPPORTED)) ? "true" : "false");
        first = 0;
    }
    printf("\n  ]\n}\n");
    cam_close(c);
    return 0;
}

static int cmd_get(cam_t *c, const char *name)
{
    const ctrl_t *k = lookup(name);
    if (!k) { fprintf(stderr, "uvcctl: unknown control '%s'\n", name); return 2; }
    if (!ctrl_supported(c, k)) { fprintf(stderr, "uvcctl: '%s' not supported by this camera\n", name); return 3; }
    if (!cam_open(c)) return 2;
    long v = 0;
    int ok = read_val(c, k, UVC_GET_CUR, &v);
    cam_close(c);
    if (!ok) { fprintf(stderr, "uvcctl: read failed for '%s'\n", name); return 4; }
    printf("%ld\n", v);
    return 0;
}

static int cmd_set(cam_t *c, const char *name, const char *valstr)
{
    const ctrl_t *k = lookup(name);
    if (!k) { fprintf(stderr, "uvcctl: unknown control '%s'\n", name); return 2; }
    if (!ctrl_supported(c, k)) { fprintf(stderr, "uvcctl: '%s' not supported by this camera\n", name); return 3; }
    if (!cam_open(c)) return 2;

    long v = strtol(valstr, NULL, 10);

    /* Clamp to the camera's own range so a bad slider value can't wedge it. */
    if (strcmp(k->kind, "range") == 0) {
        long mn, mx;
        if (read_val(c, k, UVC_GET_MIN, &mn) && read_val(c, k, UVC_GET_MAX, &mx) && mn <= mx) {
            if (v < mn) v = mn;
            if (v > mx) v = mx;
        }
    }

    uint8_t buf[8] = {0};
    encode(v, buf, k->len);
    int ok = uvc_req(c, 0, UVC_SET_CUR, k, buf, k->len);
    long back = v;
    if (ok) read_val(c, k, UVC_GET_CUR, &back);
    cam_close(c);

    if (!ok) { fprintf(stderr, "uvcctl: write failed for '%s'\n", name); return 4; }
    printf("%ld\n", back);
    return 0;
}

/*
 * A gate is an auto-mode control: while it is engaged the camera ignores
 * writes to the manual controls underneath it.
 */
static int is_gate(const ctrl_t *k)
{
    return strcmp(k->name, "white_balance_temperature_auto") == 0 ||
           strcmp(k->name, "hue_auto") == 0 ||
           strcmp(k->name, "contrast_auto") == 0 ||
           strcmp(k->name, "focus_auto") == 0 ||
           strcmp(k->name, "exposure_auto") == 0;
}

/* The value that puts a gate into manual mode. */
static long gate_manual_value(const ctrl_t *k)
{
    return strcmp(k->name, "exposure_auto") == 0 ? 1 : 0;
}

static int write_val(cam_t *c, const ctrl_t *k, long v)
{
    uint8_t buf[8] = {0};
    encode(v, buf, k->len);
    return uvc_req(c, 0, UVC_SET_CUR, k, buf, k->len);
}

static int cmd_reset(cam_t *c)
{
    if (!cam_open(c)) return 2;
    int n = 0;

    /* 1. Drop every gate to manual, otherwise the defaults below are ignored. */
    for (int i = 0; i < NCONTROLS; i++) {
        const ctrl_t *k = &CONTROLS[i];
        if (is_gate(k) && ctrl_supported(c, k)) write_val(c, k, gate_manual_value(k));
    }

    /* 2. Restore the manual values. */
    for (int i = 0; i < NCONTROLS; i++) {
        const ctrl_t *k = &CONTROLS[i];
        if (is_gate(k) || !ctrl_supported(c, k)) continue;
        long def;
        if (!read_val(c, k, UVC_GET_DEF, &def)) continue;
        if (write_val(c, k, def)) n++;
    }

    /* 3. Put the gates back to their own defaults. */
    for (int i = 0; i < NCONTROLS; i++) {
        const ctrl_t *k = &CONTROLS[i];
        if (!is_gate(k) || !ctrl_supported(c, k)) continue;
        long def;
        if (!read_val(c, k, UVC_GET_DEF, &def)) continue;
        if (write_val(c, k, def)) n++;
    }

    cam_close(c);
    printf("{\"reset\":%d}\n", n);
    return 0;
}

/* ---- watch ------------------------------------------------------------- */

/*
 * Which IORegistry class actually enumerates USB devices on this OS version.
 * Modern macOS publishes IOUSBHostDevice; the older IOUSBDevice nub still
 * exists on some paths. Registering both would double-fire every arrival, so
 * pick the one that currently lists anything.
 */
static const char *usb_class(void)
{
    static const char *classes[] = {"IOUSBHostDevice", "IOUSBDevice"};
    for (int i = 0; i < 2; i++) {
        io_iterator_t it = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                         IOServiceMatching(classes[i]), &it) == KERN_SUCCESS) {
            io_service_t s = IOIteratorNext(it);
            IOObjectRelease(it);
            if (s) {
                IOObjectRelease(s);
                return classes[i];
            }
        }
    }
    return classes[0];
}

static void on_arrival(void *refcon, io_iterator_t iter)
{
    (void)refcon;
    int n = 0;
    io_service_t s;
    /* The iterator MUST be drained or no further notifications arrive. */
    while ((s = IOIteratorNext(iter))) {
        IOObjectRelease(s);
        n++;
    }
    if (n) {
        printf("arrived %d\n", n);
        fflush(stdout);  /* stdout is block-buffered when piped */
    }
}

/*
 * Block, printing a line every time a matching camera appears. Used instead of
 * a launchd LaunchEvents rule: that mechanism requires the job to consume an
 * XPC event stream, and a job that does not gets relaunched every 10 seconds
 * forever.
 */
static int cmd_watch(uint16_t vid, uint16_t pid)
{
    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    if (!port) {
        fprintf(stderr, "uvcctl: cannot create notification port\n");
        return 2;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);

    CFMutableDictionaryRef m = IOServiceMatching(usb_class());
    if (vid) {
        int v = vid, p = pid;
        CFNumberRef cv = CFNumberCreate(NULL, kCFNumberIntType, &v);
        CFNumberRef cp = CFNumberCreate(NULL, kCFNumberIntType, &p);
        CFDictionarySetValue(m, CFSTR("idVendor"), cv);
        CFDictionarySetValue(m, CFSTR("idProduct"), cp);
        CFRelease(cv);
        CFRelease(cp);
    }

    io_iterator_t it = 0;
    kern_return_t kr = IOServiceAddMatchingNotification(
        port, kIOFirstMatchNotification, m, on_arrival, NULL, &it);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "uvcctl: cannot register for device arrival (0x%08x)\n", kr);
        return 2;
    }

    /* Arms the notification, and reports anything already plugged in. */
    on_arrival(NULL, it);
    CFRunLoopRun();
    return 0;
}

static void usage(void)
{
    fprintf(stderr,
        "uvcctl — UVC camera controls for macOS\n\n"
        "  uvcctl list\n"
        "  uvcctl caps  [-d vid:pid] [-l location]\n"
        "  uvcctl get   <control> [-d vid:pid] [-l location]\n"
        "  uvcctl set   <control> <value> [-d vid:pid] [-l location]\n"
        "  uvcctl reset [-d vid:pid] [-l location]\n"
        "  uvcctl watch [-d vid:pid]   print a line whenever the camera is plugged in\n\n"
        "vid:pid are hex, e.g. -d 0c45:6341\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(); return 1; }

    uint16_t want_vid = 0, want_pid = 0;
    uint32_t want_location = 0;
    int argn = argc;
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "--force") == 0) g_force = 1;
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "-d") == 0) {
            unsigned a = 0, b = 0;
            if (sscanf(argv[i + 1], "%x:%x", &a, &b) != 2 || !a || !b ||
                a > 0xffff || b > 0xffff) {
                fprintf(stderr, "uvcctl: invalid device id\n");
                return 1;
            }
            want_vid = (uint16_t)a;
            want_pid = (uint16_t)b;
            if (i < argn) argn = i;  /* positional args end here */
        } else if (strcmp(argv[i], "-l") == 0) {
            unsigned location = 0;
            if (sscanf(argv[i + 1], "%x", &location) != 1 || !location) {
                fprintf(stderr, "uvcctl: invalid location\n");
                return 1;
            }
            want_location = location;
            if (i < argn) argn = i;
        }
    }

    const char *cmd = argv[1];
    if (strcmp(cmd, "list") == 0) return cmd_list();
    /* watch must not require the camera to be present — that is the point. */
    if (strcmp(cmd, "watch") == 0) return cmd_watch(want_vid, want_pid);

    cam_t cams[16];
    int n = find_cameras(cams, 16, want_vid, want_pid, want_location);
    if (n == 0) {
        fprintf(stderr, "uvcctl: no matching UVC camera found\n");
        return 5;
    }
    if (n > 1) {
        fprintf(stderr, "uvcctl: %d cameras match; use -l location from 'uvcctl list'\n", n);
        for (int i = 0; i < n; i++) (*cams[i].dev)->Release(cams[i].dev);
        return 6;
    }
    cam_t *c = &cams[0];

    int rc;
    if (strcmp(cmd, "caps") == 0) rc = cmd_caps(c);
    else if (strcmp(cmd, "reset") == 0) rc = cmd_reset(c);
    else if (strcmp(cmd, "get") == 0 && argn > 2) rc = cmd_get(c, argv[2]);
    else if (strcmp(cmd, "set") == 0 && argn > 3) rc = cmd_set(c, argv[2], argv[3]);
    else { usage(); rc = 1; }

    for (int i = 0; i < n; i++) (*cams[i].dev)->Release(cams[i].dev);
    return rc;
}
