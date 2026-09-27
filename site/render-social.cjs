const {chromium}=require('playwright');
const path=require('path');
const {pathToFileURL}=require('url');
(async()=>{const browser=await chromium.launch({channel:'msedge',headless:true});try{const page=await browser.newPage({viewport:{width:1200,height:630},deviceScaleFactor:1});await page.goto(pathToFileURL(path.join(__dirname,'social-card.html')).href);await page.evaluate(async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode()));});await page.screenshot({path:path.join(__dirname,'social-card.png')});}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
