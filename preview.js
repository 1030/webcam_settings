let compareCamera = null;
const previewActive = new Set();
const previewStats = {};
const previewPatches = {};
const previewStatus = {};
const falseColours = [[98,67,185],[66,123,211],[67,200,210],[89,189,98],
                      [240,215,80],[244,155,66],[237,85,85]];

function previewName(cam) {
  return presetFor(cam)?.label || `${cam.name} · ${cam.location}`;
}

function previewOptions() {
  const select = $('compare');
  const previous = compareCamera?.location || '';
  select.replaceChildren(new Option('None', ''));
  if (current) for (const cam of cameras.filter(c => c.location !== current.location)) {
    select.add(new Option(previewName(cam), cam.location));
  }
  select.value = previous;
  if (!select.value) compareCamera = null;
}

async function previewStart(cam) {
  if (!cam || previewActive.has(cam.location)) return;
  previewActive.add(cam.location);
  try {
    await api('/api/preview/start', {location: cam.location});
  } catch (error) {
    previewStatus[cam.location] = error.message;
  }
}

function previewStopUnused() {
  const wanted = new Set([current?.location, compareCamera?.location].filter(Boolean));
  for (const location of [...previewActive]) if (!wanted.has(location)) {
    previewActive.delete(location);
    api('/api/preview/stop', {location}).catch(() => {});
  }
}

function previewSelect(cam) {
  if (compareCamera?.location === cam.location) compareCamera = null;
  $('primary-title').textContent = previewName(cam);
  $('primary-message').textContent = 'Starting preview…';
  $('primary-message').hidden = false;
  $('primary-canvas').hidden = true;
  previewOptions();
  previewStopUnused();
  previewStart(cam);
}

function samplePatch(pixels, width, height, point) {
  const px = Math.round(point.x * width), py = Math.round(point.y * height);
  const radius = Math.max(8, Math.round(Math.min(width, height) * .055));
  let r=0, g=0, b=0, count=0;
  for (let y=Math.max(0,py-radius); y<Math.min(height,py+radius); y+=2) {
    for (let x=Math.max(0,px-radius); x<Math.min(width,px+radius); x+=2) {
      const i = (y*width+x)*4;
      r += pixels[i]; g += pixels[i+1]; b += pixels[i+2]; count++;
    }
  }
  r=Math.round(r/count); g=Math.round(g/count); b=Math.round(b/count);
  return {r,g,b,brightness:Math.round((.2126*r+.7152*g+.0722*b)/2.55),px,py,radius};
}

function colourize(image, mode) {
  const pixels = image.data;
  for (let i=0; i<pixels.length; i+=4) {
    const r=pixels[i], g=pixels[i+1], b=pixels[i+2];
    const y=.2126*r+.7152*g+.0722*b;
    if (mode === 'exposure') {
      const band=y<26?0:y<51?1:y<90?2:y<140?3:y<190?4:y<230?5:6;
      [pixels[i],pixels[i+1],pixels[i+2]] = falseColours[band];
    } else if (mode === 'skin') {
      const cb=128-.169*r-.331*g+.5*b;
      const cr=128+.5*r-.419*g-.081*b;
      if (cb>77 && cb<127 && cr>133 && cr<173 && y>35) {
        pixels[i]=Math.round(r*.55+60);
        pixels[i+1]=Math.round(g*.55+110);
        pixels[i+2]=Math.round(b*.55+45);
      } else {
        const grey=Math.round(y*.43);
        pixels[i]=grey; pixels[i+1]=grey; pixels[i+2]=grey;
      }
    }
  }
}

function displaySample(slot, result) {
  const element = $(slot+'-sample');
  element.replaceChildren();
  const swatch = document.createElement('span');
  swatch.className = 'swatch';
  swatch.style.background = `rgb(${result.r},${result.g},${result.b})`;
  element.append(swatch, `Brightness ${result.brightness}% · RGB ${result.r} / ${result.g} / ${result.b}`);
}

function updateDifference() {
  if (!current || !compareCamera || !previewStats[current.location] ||
      !previewStats[compareCamera.location]) {
    $('delta').textContent = '';
    return;
  }
  const a=previewStats[current.location], b=previewStats[compareCamera.location];
  const signed=n=>(n>0?'+':'')+n;
  $('delta').textContent = `Comparison minus primary: brightness ${signed(b.brightness-a.brightness)} points · RGB ${signed(b.r-a.r)} / ${signed(b.g-a.g)} / ${signed(b.b-a.b)}. Match the same skin patch under the same light.`;
}

async function drawPreview(slot, cam) {
  if (!cam) return;
  const canvas=$(slot+'-canvas'), notice=$(slot+'-message');
  try {
    const response=await fetch('/api/preview/frame/'+cam.location,{cache:'no-store'});
    if (!response.ok) throw Error('waiting');
    const bitmap=await createImageBitmap(await response.blob());
    if ((slot==='primary'?current:compareCamera)?.location !== cam.location) {
      bitmap.close(); return;
    }
    if (canvas.width!==bitmap.width || canvas.height!==bitmap.height) {
      canvas.width=bitmap.width; canvas.height=bitmap.height;
    }
    const ctx=canvas.getContext('2d',{willReadFrequently:true});
    ctx.drawImage(bitmap,0,0);
    bitmap.close();
    const raw=ctx.getImageData(0,0,canvas.width,canvas.height);
    const point=previewPatches[cam.location] || {x:.5,y:.5};
    const result=samplePatch(raw.data,canvas.width,canvas.height,point);
    previewStats[cam.location]=result;
    const mode=$('view-mode').value;
    if (mode!=='normal') { colourize(raw,mode); ctx.putImageData(raw,0,0); }
    ctx.strokeStyle='#fff';
    ctx.lineWidth=Math.max(2,canvas.width/240);
    ctx.strokeRect(result.px-result.radius,result.py-result.radius,
                   result.radius*2,result.radius*2);
    canvas.hidden=false; notice.hidden=true;
    displaySample(slot,result);
    updateDifference();
  } catch (error) {
    if (Date.now()-(previewStatus[cam.location+'-at']||0)>1800) {
      previewStatus[cam.location+'-at']=Date.now();
      try {
        const status=await api('/api/preview/status/'+cam.location);
        previewStatus[cam.location]=status.error||status.message||'Waiting for preview…';
      } catch (statusError) {
        previewStatus[cam.location]=statusError.message;
      }
    }
    notice.textContent=previewStatus[cam.location]||'Waiting for preview…';
    notice.hidden=false;
  }
}

let previewBusy=false;
setInterval(async()=>{
  if (previewBusy || !current) return;
  previewBusy=true;
  try { await Promise.all([drawPreview('primary',current),
                           drawPreview('compare',compareCamera)]); }
  finally { previewBusy=false; }
},300);

for (const slot of ['primary','compare']) {
  $(slot+'-canvas').onclick=event=>{
    const cam=slot==='primary'?current:compareCamera;
    if (!cam) return;
    const rect=event.target.getBoundingClientRect();
    previewPatches[cam.location]={x:(event.clientX-rect.left)/rect.width,
                                  y:(event.clientY-rect.top)/rect.height};
  };
}

$('compare').onchange=()=>{
  compareCamera=cameras.find(c=>c.location===$('compare').value)||null;
  $('compare-title').textContent=compareCamera?previewName(compareCamera):'Comparison';
  $('compare-message').textContent=compareCamera?'Starting preview…':'Choose another camera above.';
  $('compare-message').hidden=false;
  $('compare-canvas').hidden=true;
  previewStopUnused();
  if (compareCamera) previewStart(compareCamera);
  else {
    $('compare-sample').textContent='Use the same skin and light for comparison.';
    $('delta').textContent='';
  }
};

$('view-mode').onchange=()=>{
  $('legend').hidden=$('view-mode').value!=='exposure';
  $('view-note').textContent=$('view-mode').value==='skin'
    ? 'Skin region guide highlights approximate skin-coloured pixels. Lighting and complexion vary; use the clicked patch values for matching.'
    : 'Click a skin patch in each preview. The boxes report average RGB and display brightness. False colour is a visual guide, not a calibrated exposure meter.';
};

window.addEventListener('pagehide',()=>{
  for (const location of previewActive) {
    navigator.sendBeacon('/api/preview/stop',
      new Blob([JSON.stringify({location})],{type:'application/json'}));
  }
});
