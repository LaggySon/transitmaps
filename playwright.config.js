import {defineConfig, devices} from "@playwright/test"

const chromiumExecutable = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : 2,
  reporter: [["list"], ["html", {open: "never"}]],
  snapshotPathTemplate: "{testDir}/__screenshots__/{testFilePath}/{arg}{ext}",
  expect: {
    timeout: 10_000,
    toHaveScreenshot: {
      animations: "disabled",
      caret: "hide",
      maxDiffPixelRatio: 0.005,
    },
  },
  use: {
    baseURL: "http://localhost:4000",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    viewport: {width: 1280, height: 800},
    launchOptions: chromiumExecutable
      ? {
          executablePath: chromiumExecutable,
          args: [
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--use-gl=angle",
            "--use-angle=swiftshader",
            "--enable-unsafe-swiftshader",
          ],
        }
      : {},
  },
  projects: [
    {
      name: "chromium",
      use: {...devices["Desktop Chrome"]},
    },
  ],
  webServer: {
    command: "mix ecto.create --quiet && mix ecto.migrate --quiet && mix phx.server",
    env: {
      ...process.env,
      MIX_ENV: "test",
      PHX_SERVER: "true",
      PORT: "4000",
    },
    url: "http://localhost:4000/health",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
})
