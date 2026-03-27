import fs from 'fs';

import { CONFIG } from './config';

export const log = (level: 'INFO' | 'ERROR', message: string): void => {
    const ts = new Date().toISOString();
    const line = `[${ts}] [${level}] ${message}`;
    console.log(line);
    try {
        fs.appendFileSync(CONFIG.LOG_FILE, `${line}\n`);
    } catch {
        // Logging to file is best-effort only.
    }
};
