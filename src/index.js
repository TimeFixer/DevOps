const { chromium } = require('playwright');
const fs = require('fs').promises;
const path = require('path');

(async () => {
  // Указываем путь к системному Chromium, установленному в Docker через apt-get
  const browser = await chromium.launch({
    executablePath: '/usr/bin/chromium'
  });
  
  const page = await browser.newPage();
  
  try {
    await page.goto('https://quotes.toscrape.com/scroll', { waitUntil: 'networkidle' });
    
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

    // Создаем директорию out и записываем результат
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