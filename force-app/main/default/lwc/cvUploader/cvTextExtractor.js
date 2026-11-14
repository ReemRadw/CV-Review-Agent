/**
 * Client-side text extraction for CV files.
 * PDF  -> PDF.js running in the CvPdfReader Visualforce page (hidden iframe),
 *         because PDF.js is not reliable inside Lightning Web Security.
 * DOCX -> mammoth.js loaded as a static resource.
 * TXT  -> TextDecoder.
 */
import { loadScript } from 'lightning/platformResourceLoader';
import MAMMOTH from '@salesforce/resourceUrl/mammoth';

// Low on purpose: a short but real CV (name + a few skills) must still become a
// card with its gaps flagged. Scanned PDFs produce no text at all, so they still fail.
const MIN_MEANINGFUL_CHARS = 15;
const PDF_TIMEOUT_MS = 30000;
const VF_ORIGIN = /^https:\/\/[a-z0-9.-]+\.force\.com$/i;

export const SUPPORTED_EXTENSIONS = ['pdf', 'docx', 'txt'];
export const PDF_READER_URL = '/apex/CvPdfReader';

let mammothPromise;

export function loadLibraries(component) {
    if (!mammothPromise) {
        mammothPromise = loadScript(component, MAMMOTH);
        mammothPromise.catch(() => {
            mammothPromise = undefined; // allow a retry on the next call
        });
    }
    return mammothPromise;
}

/**
 * Talks to the CvPdfReader iframe. One instance per component.
 */
export class PdfBridge {
    constructor() {
        this.pending = new Map();
        this.sequence = 0;
        this.target = null;
        this.origin = null;
        this.ready = new Promise((resolve) => {
            this.resolveReady = resolve;
        });
        this.handleMessage = this.handleMessage.bind(this);
    }

    connect() {
        window.addEventListener('message', this.handleMessage);
    }

    disconnect() {
        window.removeEventListener('message', this.handleMessage);
        this.pending.forEach(({ reject }) => reject(new Error('Upload component was closed.')));
        this.pending.clear();
    }

    /** Called on iframe load in case the first "ready" message was missed. */
    ping(frameWindow) {
        if (frameWindow) {
            frameWindow.postMessage({ type: 'cv-pdf-ping' }, '*');
        }
    }

    handleMessage(event) {
        const msg = event.data;
        if (!msg || !VF_ORIGIN.test(event.origin)) {
            return;
        }
        if (msg.type === 'cv-pdf-ready') {
            this.target = event.source;
            this.origin = event.origin;
            this.resolveReady();
        } else if (msg.type === 'cv-pdf-result' && this.pending.has(msg.id)) {
            const { resolve, reject, timer } = this.pending.get(msg.id);
            clearTimeout(timer);
            this.pending.delete(msg.id);
            if (msg.error) {
                reject(new Error(`PDF could not be read (${msg.error}).`));
            } else {
                resolve(msg.text);
            }
        }
    }

    async extract(buffer) {
        await withTimeout(this.ready, 20000, 'The PDF reader did not load. Check access to the CvPdfReader page.');
        const id = `pdf-${++this.sequence}`;
        return new Promise((resolve, reject) => {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            const timer = setTimeout(() => {
                this.pending.delete(id);
                reject(new Error('Reading the PDF timed out.'));
            }, PDF_TIMEOUT_MS);
            this.pending.set(id, { resolve, reject, timer });
            // Send a copy so the original buffer stays usable for the attachment.
            this.target.postMessage({ type: 'cv-pdf-extract', id, buffer: buffer.slice(0) }, this.origin);
        });
    }
}

function withTimeout(promise, ms, message) {
    let timer;
    return Promise.race([
        promise,
        new Promise((resolve, reject) => {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            timer = setTimeout(() => reject(new Error(message)), ms);
        })
    ]).finally(() => clearTimeout(timer));
}

export function getExtension(fileName) {
    const parts = (fileName || '').toLowerCase().split('.');
    return parts.length > 1 ? parts.pop() : '';
}

export function readAsArrayBuffer(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error('The browser could not read the file.'));
        reader.readAsArrayBuffer(file);
    });
}

export function arrayBufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    const chunkSize = 0x8000;
    let binary = '';
    for (let i = 0; i < bytes.length; i += chunkSize) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
    }
    return window.btoa(binary);
}

async function extractDocx(buffer) {
    const result = await window.mammoth.extractRawText({ arrayBuffer: buffer });
    return result.value;
}

/** Collapse noisy whitespace while keeping line structure (headings matter for parsing). */
export function cleanText(raw) {
    return (raw || '')
        .replace(/\r/g, '')
        .replace(/[ \t ]+/g, ' ')
        .replace(/ *\n */g, '\n')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
}

export async function extractText(fileName, buffer, pdfBridge) {
    const ext = getExtension(fileName);
    let raw;
    if (ext === 'pdf') {
        raw = await pdfBridge.extract(buffer);
    } else if (ext === 'docx') {
        raw = await extractDocx(buffer);
    } else if (ext === 'txt') {
        raw = new TextDecoder('utf-8').decode(buffer);
    } else {
        throw new Error(`Unsupported file type ".${ext}". Use PDF, DOCX or TXT.`);
    }

    const text = cleanText(raw);
    if (text.replace(/\s/g, '').length < MIN_MEANINGFUL_CHARS) {
        throw new Error(
            ext === 'pdf'
                ? 'No text layer found - this looks like a scanned/image PDF. OCR is not supported.'
                : 'The file has almost no readable text.'
        );
    }
    return text;
}
