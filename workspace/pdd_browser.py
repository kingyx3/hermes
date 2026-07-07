import asyncio
import os
import sys
from playwright.async_api import async_playwright

async def main():
    os.environ["PLAYWRIGHT_BROWSERS_PATH"] = "/home/hermes/workspace/ms-playwright"
    async with async_playwright() as p:
        # Launch chromium
        browser = await p.chromium.launch(headless=True)
        
        # Check if state exists
        state_path = "/home/hermes/workspace/pdd_state.json"
        if os.path.exists(state_path):
            context = await browser.new_context(
                viewport={"width": 375, "height": 812},
                user_agent="Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
                storage_state=state_path
            )
        else:
            context = await browser.new_context(
                viewport={"width": 375, "height": 812},
                user_agent="Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
            )
            
        page = await context.new_page()
        
        # Navigate
        print("Navigating to Yangkeduo...")
        await page.goto("https://mobile.yangkeduo.com/", wait_until="networkidle", timeout=30000)
        
        # Save screenshot
        screenshot_path = "/home/hermes/workspace/pdd_screen.png"
        await page.screenshot(path=screenshot_path)
        print(f"Screenshot saved to {screenshot_path}")
        
        # Save state
        await context.storage_state(path=state_path)
        print(f"Storage state saved to {state_path}")
        
        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
