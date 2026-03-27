export type AnalyzeMode = 'prompt' | 'reference' | 'both';

export interface AnalyzePayload {
    image?: string;
    mode?: AnalyzeMode;
    prompt?: string;
    reference?: string;
}

export interface AnalyzeFilePayload {
    imagePath?: string;
    mode?: AnalyzeMode;
    prompt?: string;
    referencePath?: string;
}

export interface ClaudeMessageContent {
    type: 'image' | 'text';
    source?: {
        type: 'base64';
        media_type: 'image/jpeg';
        data: string;
    };
    text?: string;
}

export interface ClaudeApiResponse {
    error?: {
        message?: string;
    };
    content?: Array<{
        text?: string;
    }>;
}

export interface ServerConfig {
    PORT: number;
    API_KEY: string;
    MODEL: string;
    MAX_TOKENS: number;
    LOG_FILE: string;
    MAX_BODY_SIZE_BYTES: number;
    VERSION: string;
}

export interface RequestResult {
    status: number;
    body: string;
}

export type TestMode = AnalyzeMode | 'health';

export interface TestPayload {
    image: string;
    mode: AnalyzeMode;
    prompt?: string;
    reference?: string;
}
