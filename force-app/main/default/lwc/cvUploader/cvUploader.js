import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import processCv from '@salesforce/apex/CvIngestionController.processCv';
import getRecentCandidates from '@salesforce/apex/CvIngestionController.getRecentCandidates';
import {
    SUPPORTED_EXTENSIONS,
    loadLibraries,
    getExtension,
    readAsArrayBuffer,
    arrayBufferToBase64,
    extractText
} from './cvTextExtractor';

const MAX_FILE_BYTES = 10 * 1024 * 1024;
// Aura request payload is capped at ~4 MB; base64 adds ~33%.
const MAX_ATTACH_BYTES = 2.5 * 1024 * 1024;
const PARALLEL_UPLOADS = 2;

const STAGES = {
    queued: { label: 'Queued', progress: 0 },
    reading: { label: 'Reading file', progress: 20 },
    extracting: { label: 'Extracting text', progress: 45 },
    analyzing: { label: 'Building candidate card', progress: 75 },
    done: { label: 'Saved', progress: 100 },
    error: { label: 'Failed', progress: 100 }
};

const STATUS_THEME = {
    Complete: 'success',
    Partial: 'warning',
    'Needs Review': 'error'
};

let keySeed = 0;

export default class CvUploader extends NavigationMixin(LightningElement) {
    @track items = [];
    recentCandidates = [];
    isDragging = false;
    isProcessing = false;
    librariesReady = false;
    libraryError;

    acceptAttr = SUPPORTED_EXTENSIONS.map((ext) => `.${ext}`).join(',');

    connectedCallback() {
        this.loadRecent();
    }

    renderedCallback() {
        if (this.librariesReady || this.libraryError) {
            return;
        }
        loadLibraries(this)
            .then(() => {
                this.librariesReady = true;
            })
            .catch((error) => {
                this.libraryError = 'Could not load the PDF/DOCX readers: ' + this.errorMessage(error);
            });
    }

    // ------------------------------------------------------------ getters

    get hasItems() {
        return this.items.length > 0;
    }

    get dropzoneClass() {
        return 'dropzone' + (this.isDragging ? ' dropzone_active' : '') + (this.isDisabled ? ' dropzone_disabled' : '');
    }

    get isDisabled() {
        return !this.librariesReady;
    }

    get canProcess() {
        return !this.isProcessing && this.librariesReady && this.items.some((i) => i.stage === 'queued');
    }

    get processDisabled() {
        return !this.canProcess;
    }

    get clearDisabled() {
        return this.isProcessing || !this.hasItems;
    }

    get queuedCount() {
        return this.items.filter((i) => i.stage === 'queued').length;
    }

    get processLabel() {
        return this.queuedCount > 1 ? `Analyze ${this.queuedCount} CVs` : 'Analyze CV';
    }

    get stats() {
        const done = this.items.filter((i) => i.stage === 'done');
        return [
            { key: 'total', label: 'Files', value: this.items.length, css: 'stat' },
            { key: 'ok', label: 'Complete', value: done.filter((i) => i.result.status === 'Complete').length, css: 'stat stat_success' },
            { key: 'partial', label: 'Partial', value: done.filter((i) => i.result.status === 'Partial').length, css: 'stat stat_warning' },
            { key: 'review', label: 'Needs review', value: done.filter((i) => i.result.status === 'Needs Review').length, css: 'stat stat_error' },
            { key: 'failed', label: 'Failed', value: this.items.filter((i) => i.stage === 'error').length, css: 'stat stat_muted' }
        ];
    }

    get hasRecent() {
        return this.recentCandidates.length > 0;
    }

    // ------------------------------------------------------- file intake

    handleDragOver(event) {
        event.preventDefault();
        if (!this.isDisabled) {
            this.isDragging = true;
        }
    }

    handleDragLeave() {
        this.isDragging = false;
    }

    handleDrop(event) {
        event.preventDefault();
        this.isDragging = false;
        if (!this.isDisabled) {
            this.addFiles(event.dataTransfer.files);
        }
    }

    openFilePicker() {
        if (!this.isDisabled) {
            this.template.querySelector('input[type="file"]').click();
        }
    }

    handleDropzoneKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.openFilePicker();
        }
    }

    handleFileInput(event) {
        this.addFiles(event.target.files);
        event.target.value = null; // allow picking the same file again
    }

    addFiles(fileList) {
        const existing = new Set(this.items.map((i) => `${i.name}|${i.size}`));
        const added = [];
        Array.from(fileList || []).forEach((file) => {
            if (existing.has(`${file.name}|${file.size}`)) {
                return;
            }
            const item = this.newItem(file);
            const ext = getExtension(file.name);
            if (!SUPPORTED_EXTENSIONS.includes(ext)) {
                this.fail(item, ext === 'doc' ? 'Legacy .doc is not supported - save it as .docx or PDF.' : `Unsupported file type ".${ext}".`);
            } else if (file.size === 0) {
                this.fail(item, 'The file is empty.');
            } else if (file.size > MAX_FILE_BYTES) {
                this.fail(item, 'File is larger than 10 MB.');
            }
            added.push(item);
        });
        this.items = [...this.items, ...added];
    }

    newItem(file) {
        const ext = getExtension(file.name);
        const item = {
            key: `cv-${++keySeed}`,
            file,
            name: file.name,
            size: file.size,
            sizeLabel: this.formatSize(file.size),
            iconName: ext === 'pdf' ? 'doctype:pdf' : ext === 'docx' ? 'doctype:word' : 'doctype:txt',
            result: null,
            error: null,
            warning: null
        };
        this.setStage(item, 'queued');
        return item;
    }

    removeItem(event) {
        const key = event.currentTarget.dataset.key;
        this.items = this.items.filter((i) => i.key !== key || this.isBusy(i));
    }

    clearAll() {
        this.items = [];
    }

    // --------------------------------------------------------- processing

    async processAll() {
        this.isProcessing = true;
        const queue = this.items.filter((i) => i.stage === 'queued');
        const workers = Array.from({ length: Math.min(PARALLEL_UPLOADS, queue.length) }, async () => {
            while (queue.length) {
                // eslint-disable-next-line no-await-in-loop
                await this.processItem(queue.shift());
            }
        });
        await Promise.all(workers);
        this.isProcessing = false;
        this.loadRecent();
        this.notifySummary();
    }

    async processItem(item) {
        try {
            this.update(item, 'reading');
            const buffer = await readAsArrayBuffer(item.file);

            this.update(item, 'extracting');
            const text = await extractText(item.name, buffer);

            let base64 = null;
            if (item.size <= MAX_ATTACH_BYTES) {
                base64 = arrayBufferToBase64(buffer);
            } else {
                item.warning = 'File too large to attach - only the extracted text was saved.';
            }

            this.update(item, 'analyzing');
            const result = await processCv({ fileName: item.name, cvText: text, base64File: base64 });
            item.result = this.decorateResult(result);
            this.update(item, 'done');
        } catch (error) {
            this.fail(item, this.errorMessage(error));
            this.refreshItems();
        }
    }

    decorateResult(result) {
        const theme = STATUS_THEME[result.status] || 'info';
        const skills = result.skills || [];
        return {
            ...result,
            badgeClass: `status-badge status-badge_${theme}`,
            experienceLabel: result.yearsOfExperience != null ? `${result.yearsOfExperience} yrs` : 'Years n/a',
            hasSkills: skills.length > 0,
            topSkills: skills.slice(0, 6),
            moreSkills: skills.length > 6 ? `+${skills.length - 6}` : null,
            hasMissing: (result.missingFields || []).length > 0,
            hasConflicts: (result.conflicts || []).length > 0,
            sourceLabel: result.updatedExisting ? 'Updated existing candidate' : 'New candidate',
            isFallback: result.parsedBy !== 'Prompt Template'
        };
    }

    // ------------------------------------------------------------- state

    setStage(item, stage) {
        const def = STAGES[stage];
        item.stage = stage;
        item.stageLabel = def.label;
        item.progress = def.progress;
        item.isDone = stage === 'done';
        item.isError = stage === 'error';
        item.isActive = !item.isDone && !item.isError && stage !== 'queued';
        item.canRemove = !item.isActive;
        item.rowClass = `file-row file-row_${stage}`;
        item.progressStyle = `width:${def.progress}%`;
    }

    update(item, stage) {
        this.setStage(item, stage);
        this.refreshItems();
    }

    fail(item, message) {
        item.error = message;
        this.setStage(item, 'error');
    }

    refreshItems() {
        this.items = [...this.items];
    }

    isBusy(item) {
        return item.isActive;
    }

    // ------------------------------------------------------ recent list

    loadRecent() {
        getRecentCandidates({ limitSize: 8 })
            .then((rows) => {
                this.recentCandidates = rows.map((row) => ({
                    ...row,
                    badgeClass: `status-badge status-badge_${STATUS_THEME[row.Data_Status__c] || 'info'}`,
                    yearsLabel: row.Years_of_Experience__c != null ? `${row.Years_of_Experience__c} yrs` : '—'
                }));
            })
            .catch(() => {
                this.recentCandidates = [];
            });
    }

    openRecord(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, actionName: 'view' }
        });
    }

    // ----------------------------------------------------------- helpers

    notifySummary() {
        const saved = this.items.filter((i) => i.stage === 'done').length;
        const failed = this.items.filter((i) => i.stage === 'error').length;
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'CV processing finished',
                message: `${saved} saved, ${failed} failed.`,
                variant: failed ? (saved ? 'warning' : 'error') : 'success'
            })
        );
    }

    formatSize(bytes) {
        if (bytes < 1024) {
            return `${bytes} B`;
        }
        if (bytes < 1024 * 1024) {
            return `${(bytes / 1024).toFixed(0)} KB`;
        }
        return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
    }

    errorMessage(error) {
        if (!error) {
            return 'Unknown error';
        }
        if (error.body && error.body.message) {
            return error.body.message;
        }
        return error.message || String(error);
    }
}
