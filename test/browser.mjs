import assert from 'node:assert/strict';
const {chromium} = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const browser = await chromium.launch({executablePath: process.env.CHROMIUM_BIN || undefined, headless:true, args:['--no-sandbox']});
const base = process.env.BASE_URL || 'http://127.0.0.1:18792';
try {
 for (const width of [1280,390,320]) {
  const page = await browser.newPage({viewport:{width,height:1000}, reducedMotion:'reduce'});
  const errors=[];
  page.on('pageerror', e=>errors.push(e.message));
  await page.goto(base,{waitUntil:'networkidle'});
  assert.equal(await page.title(),'mayfly :: little files, brief lives');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth),true,`overflow at ${width}`);
  assert.equal(await page.locator('.mascots img').evaluate(img=>img.complete && img.naturalWidth>0),true,'anime artwork loaded');
  assert.equal(await page.locator('#how').getAttribute('open'),null);
  await page.screenshot({path:`/tmp/mayfly-${width}.png`,fullPage:true});
  await page.locator('#file').setInputFiles({name:'browser-test.txt',mimeType:'text/plain',buffer:Buffer.from('mayfly browser test')});
  await page.locator('#send').click();
  await page.locator('#result').waitFor({state:'visible'});
  const link=await page.locator('#link').inputValue();
  const download=await page.request.get(link);
  assert.equal(download.status(),200);
  assert.equal(await download.text(),'mayfly browser test');
  page.on('dialog', dialog=>dialog.accept());
  await page.locator('#result summary').click();
  await page.locator('#delete').click();
  await page.waitForFunction(()=>document.getElementById('delete').disabled);
  assert.equal((await page.request.get(link)).status(),404);
  assert.deepEqual(errors,[]);
  console.log(`${width}px: upload, result, download, deletion, no overflow or JS errors`);
  await page.close();
 }
} finally { await browser.close(); }
