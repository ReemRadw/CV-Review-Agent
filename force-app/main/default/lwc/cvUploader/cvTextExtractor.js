/**
 * Client-side text extraction for CV files.
 * PDF  -> PDF.js (runs on the main thread, no web worker needed under LWS)
 * DOCX -> mammoth.js
 * TXT  -> plain FileReader
 */
import { loadScript } from 'lightning/platformResourceLoader';
import PDFJS from '@salesforce/resourceUrl/pdfjs';
import MAMMOTH from '@salesforce/resourceUrl/mammoth';

const MIN_MEANINGFUL_CHARS = 40;

export const SUPPORTED_EXTENSIONS = ['pdf', 'docx', 'txt'];

let librariesPromise;

export function loadLibraries(component) {
    if (!librariesPromise) {
        librariesPromise = Promise.all([
            loadScript(component, `${PDFJS}/pdf.min.js`).then(() =>
                // Loading the worker script exposes window.pdfjsWorker, which makes
                // PDF.js parse on the main thread instead of spawning a Worker.
                loadScript(component, `${PDFJS}/pdf.worker.min.js`)
            ),
            loadScript(component, MAMMOTH)
        ]).then(() => {
            window.pdfjsLib.GlobalWorkerOptions.workerSrc = `${PDFJS}/pdf.worker.min.js`;
        });
        librariesPromise.catch(() => {
            librariesPromise = undefined; // allow a retry on the next call
        });
    }
    return librariesPromise;
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

async function extractPdf(buffer) {
    // PDF.js detaches the buffer it receives, so hand it a copy.
    const pdf = await window.pdfjsLib.getDocument({
        data: new Uint8Array(buffer.slice(0)),
        isEvalSupported: false
    }).promise;

    const pages = [];
    for (let pageNo = 1; pageNo <= pdf.numPages; pageNo++) {
        const page = await pdf.getPage(pageNo);
        const content = await page.getTextContent();
        let lastY = null;
        let text = '';
        for (const item of content.items) {
            const y = item.transform[5];
            if (lastY !== null && Math.abs(y - lastY) > 2) {
                text += '\n';
            } else if (text && !text.endsWith(' ') && item.str && !item.str.startsWith(' ')) {
                text += ' ';
            }
            text += item.str;
            lastY = y;
        }
        pages.push(text);
    }
    return pages.join('\n\n');
}

async function extractDocx(buffer) {
    const result = await window.mammoth.extractRawText({ arrayBuffer: buffer });
    return result.value;
}

function extractTxt(buffer) {
    return new TextDecoder('utf-8').decode(buffer);
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

export async function extractText(fileName, buffer) {
    const ext = getExtension(fileName);
    let raw;
    if (ext === 'pdf') {
        raw = await extractPdf(buffer);
    } else if (ext === 'docx') {
        raw = await extractDocx(buffer);
    } else if (ext === 'txt') {
        raw = extractTxt(buffer);
    } else {
        throw new Error(`Unsupported file type ".${ext}". Use PDF, DOCX or TXT.`);
    }

    const text = cleanText(raw);
    if (text.replace(/\s/g, '').length < MIN_MEANINGFUL_CHARS) {
        throw new Error(
            ext === 'pdf'
                ? 'No text layer found - this looks like a scanned/image PDF.'
                : 'The file has almost no readable text.'
        );
    }
    return text;
}
