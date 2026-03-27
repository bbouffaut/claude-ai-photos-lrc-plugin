import fs from 'fs';
import path from 'path';

import { ServerConfig } from './types';

const loadEnvFile = (envFilePath: string): void => {
    if (!fs.existsSync(envFilePath)) {
        return;
    }

    const content = fs.readFileSync(envFilePath, 'utf8');
    for (const rawLine of content.split(/\r?\n/)) {
        const line = rawLine.trim();
        if (!line || line.startsWith('#')) {
            continue;
        }

        const separatorIndex = line.indexOf('=');
        if (separatorIndex === -1) {
            continue;
        }

        const key = line.slice(0, separatorIndex).trim();
        let value = line.slice(separatorIndex + 1).trim();

        if (
            (value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'"))
        ) {
            value = value.slice(1, -1);
        }

        if (!(key in process.env)) {
            process.env[key] = value;
        }
    }
};

const resolveEnvFilePath = (): string => {
    const configuredPath = process.env.ENV_FILE ?? '.env';
    return path.isAbsolute(configuredPath)
        ? configuredPath
        : path.resolve(process.cwd(), configuredPath);
};

loadEnvFile(resolveEnvFilePath());

export const CONFIG: ServerConfig = {
    PORT: Number(process.env.PORT ?? 3000),
    API_KEY: process.env.ANTHROPIC_API_KEY ?? process.env.anthropic_key ?? '',
    SERVER_URL: process.env.SERVER_URL ?? process.env.SEVER_URL ?? 'http://localhost:3000',
    MODEL: 'claude-sonnet-4-6',
    MAX_TOKENS: 2048,
    LOG_FILE: path.join(__dirname, '..', 'claude_photo_server.log'),
    MAX_BODY_SIZE_BYTES: 16 * 1024 * 1024,
    VERSION: '2.0.0',
};
