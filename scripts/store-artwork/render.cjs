// Compose store cards from native captures. Run after `just shots store-shots`.
// Requires Playwright with Microsoft Edge; output is dist/store-artwork/.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const root = path.resolve(__dirname, '../..');
const output = path.join(root, 'dist/store-artwork');
const uri = p => pathToFileURL(path.join(root, p)).href;
const esc = s => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');
const copy = {
  transcript: ['Your meetings.\nReady to read.', 'A transcript, summary, and action items in one place.'],
  take: ['From recording\nto next steps.', 'Keep the audio, transcript, and summary together.'],
  library: ['Every conversation,\nclose at hand.', 'Browse your recordings and shared transcripts.'],
  recorder: ['Record wherever\nyou are.', 'Capture a conversation or a voice note on your device.'],
};
function mobile(kind, file) {
  const [w,h] = kind === 'iphone' ? [1320,2868] : [2064,2752];
  const key = file.replace(/^\d+-/, '').replace('.png','');
  if (!copy[key]) throw new Error('Missing caption for '+file);
  const [title,sub] = copy[key];
  return `<!doctype html><meta charset="utf-8"><style>
  *{box-sizing:border-box}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#f7f4ff}
  .frame{width:${w}px;height:${h}px;position:relative;overflow:hidden;background:radial-gradient(ellipse at 80% 55%,#39224f,transparent 65%),linear-gradient(140deg,#14101c,#050407)}
  .brand{position:absolute;left:7%;top:3.5%;display:flex;align-items:center;gap:25px;font-size:${kind==='iphone'?42:50}px;font-weight:600}.brand img{width:82px;height:82px}
  .copy{position:absolute;top:9.8%;left:7%;right:7%}h1{font-size:${kind==='iphone'?110:132}px;line-height:1.05;letter-spacing:-5px;margin:0 0 32px;font-weight:650}h1 em{font-style:normal;color:#bc9fff}p{color:#bcb3cd;font-size:${kind==='iphone'?44:50}px;line-height:1.4;margin:0;max-width:1500px}
  .screen{position:absolute;top:28%;bottom:5%;left:7%;right:7%;display:flex;justify-content:center;align-items:center}.screen img{max-width:100%;max-height:100%;object-fit:contain;border:2px solid #ffffff33;border-radius:${kind==='iphone'?52:30}px;box-shadow:0 40px 90px #0009}
  </style><section class="frame"><div class="brand"><img src="${uri('docs/assets/icon.png')}" alt="">Transcripts</div><div class="copy"><h1>${esc(title).replace('\n','<br><em>')}</em></h1><p>${esc(sub)}</p></div><div class="screen"><img src="${uri('dist/appstore/'+kind+'/'+file)}" alt="${esc(key)}"></div></section>`;
}
(async()=>{
  const browser=await chromium.launch({channel:'msedge',headless:true});
  try {
    const page=await browser.newPage({viewport:{width:2880,height:1800},deviceScaleFactor:1});
    await page.goto(pathToFileURL(path.join(__dirname,'mac.html')).href);
    await page.addStyleTag({content:'main{max-width:none;width:2880px;padding:0}.frame{margin:0}'});
    await page.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode()));});
    fs.mkdirSync(path.join(output,'mac'),{recursive:true});
    for(const id of ['01-menu','02-overlay','03-transcript','04-summary']) {
      await page.locator('[id="'+id+'"]').screenshot({path:path.join(output,'mac',id+'.png')});
      console.log('mac/'+id+'.png');
    }
    for(const kind of ['iphone','ipad']) {
      fs.mkdirSync(path.join(output,kind),{recursive:true});
      const files=fs.readdirSync(path.join(root,'dist/appstore',kind)).filter(f=>f.endsWith('.png')).sort();
      if(files.length<3)throw new Error('Missing native captures for '+kind);
      for(const file of files) {
        const html=path.join(output,kind,file.replace('.png','.html'));
        fs.writeFileSync(html,mobile(kind,file));
        await page.setViewportSize(kind==='iphone'?{width:1320,height:2868}:{width:2064,height:2752});
        await page.goto(pathToFileURL(html).href);
        await page.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode()));});
        const overlaps=await page.evaluate(()=>document.querySelector('.copy').getBoundingClientRect().bottom>document.querySelector('.screen').getBoundingClientRect().top);
        if(overlaps)throw new Error('Caption overlaps capture: '+kind+'/'+file);
        await page.locator('.frame').screenshot({path:path.join(output,kind,file)});
        console.log(kind+'/'+file);
      }
    }
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
