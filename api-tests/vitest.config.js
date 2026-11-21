import { defineConfig } from 'vitest/config';

const baseURL = process.env.MAIDEN_BASE_URL || 'http://127.0.0.1:5000';

export default defineConfig({
  test: {
    env: {
      MAIDEN_BASE_URL: baseURL,
    },
    fileParallelism: false,
    sequence: {
      concurrent: false,
    },
    testTimeout: 20000,
  },
});
