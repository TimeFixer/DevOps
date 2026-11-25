const { chromium } = require('playwright');
const fs = require('fs').promises;
const path = require('path');

(async () => {
  // Указываем путь к системному Chromium, установленному в Docker через apt-get
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM_PATH || undefined
  });
  
  const page = await browser.newPage();
  
  try {
    const targetUrl = process.env.SCRAPE_URL || 'https://quotes.toscrape.com/scroll';
    await page.goto(targetUrl, { waitUntil: 'networkidle' });
    
    // Ждем появления первых цитат
    await page.waitForSelector('.quote');
    
    // Прокручиваем страницу в самый низ до упора
    let previousHeight = 0;
    while (true) {
      previousHeight = await page.evaluate('document.body.scrollHeight');
      await page.evaluate('window.scrollTo(0, document.body.scrollHeight)');
      
      // Даем сайту 1 секунду на сетевой запрос и рендер новых цитат
      await page.waitForTimeout(1000); 
      
      let newHeight = await page.evaluate('document.body.scrollHeight');
      if (newHeight === previousHeight) {
        break; // Достигли дна, новые элементы не появились
      }
    }
    
    // Собираем данные со всей полностью загруженной страницы
    const quotes = await page.evaluate(() => {
      return Array.from(document.querySelectorAll('.quote')).map(el => ({
        text: el.querySelector('.text').innerText,
        author: el.querySelector('.author').innerText,
        tags: Array.from(el.querySelectorAll('.tag')).map(tag => tag.innerText)
      }));
    });

    const outputFile = process.env.OUTPUT_PATH || path.join(__dirname, '..', 'out', 'result.json');
    await fs.mkdir(path.dirname(outputFile), { recursive: true });
    await fs.writeFile(outputFile, JSON.stringify(quotes, null, 2));
    
    console.log(`Успешно сохранено ${quotes.length} цитат.`);
  } catch (error) {
    console.error('Ошибка при скрапинге:', error);
    process.exit(1);
  } finally {
    await browser.close();
  }
})();