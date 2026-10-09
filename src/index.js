const { chromium } = require('playwright');
const fs = require('fs').promises;
const path = require('path');

(async () => {
  const browser = await chromium.launch({
    executablePath: '/usr/bin/chromium'
  });
  
  const page = await browser.newPage();
  
  try {
    await page.goto('https://quotes.toscrape.com/scroll', { waitUntil: 'networkidle' });
    await page.waitForSelector('.quote');
    
    const quotes = await page.evaluate(() => {
      return Array.from(document.querySelectorAll('.quote')).map(el => ({
        text: el.querySelector('.text').innerText,
        author: el.querySelector('.author').innerText,
        tags: Array.from(el.querySelectorAll('.tag')).map(tag => tag.innerText)
      }));
    });

    const outDir = path.join(__dirname, '..', 'out');
    await fs.mkdir(outDir, { recursive: true });
    await fs.writeFile(path.join(outDir, 'result.json'), JSON.stringify(quotes, null, 2));
    
    console.log(`Успешно сохранено ${quotes.length} цитат.`);
  } catch (error) {
    console.error('Ошибка при скрапинге:', error);
    process.exit(1);
  } finally {
    await browser.close();
  }
})();