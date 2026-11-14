import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import NAME from '@salesforce/schema/Candidate__c.Name';
import TITLE from '@salesforce/schema/Candidate__c.Title__c';
import EMAIL from '@salesforce/schema/Candidate__c.Email__c';
import PHONE from '@salesforce/schema/Candidate__c.Phone__c';
import YEARS from '@salesforce/schema/Candidate__c.Years_of_Experience__c';
import SKILLS from '@salesforce/schema/Candidate__c.Skills__c';
import EXPERIENCE from '@salesforce/schema/Candidate__c.Experience__c';
import EDUCATION from '@salesforce/schema/Candidate__c.Education__c';
import ACHIEVEMENTS from '@salesforce/schema/Candidate__c.Achievements__c';
import MISSING from '@salesforce/schema/Candidate__c.Missing_Info__c';
import UNCERTAIN from '@salesforce/schema/Candidate__c.Uncertain_Info__c';
import CONFLICTS from '@salesforce/schema/Candidate__c.Conflicts__c';
import STATUS from '@salesforce/schema/Candidate__c.Data_Status__c';

const FIELDS = [NAME, TITLE, EMAIL, PHONE, YEARS, SKILLS, EXPERIENCE, EDUCATION, ACHIEVEMENTS, MISSING, UNCERTAIN, CONFLICTS, STATUS];

const STATUS_THEME = {
    Complete: { css: 'success', hint: 'All key fields found and nothing to verify.' },
    Partial: { css: 'warning', hint: 'Some information is missing or uncertain.' },
    'Needs Review': { css: 'error', hint: 'The CV contains conflicting information.' }
};

/** "• a\n• b" or "a, b" -> ['a', 'b'] */
function toList(value, separator) {
    if (!value) {
        return [];
    }
    return value
        .split(separator)
        .map((item) => item.replace(/^[•\-\s]+/, '').trim())
        .filter((item) => item.length > 0);
}

function withKeys(items) {
    return items.map((text, index) => ({ key: `${index}-${text}`, text }));
}

/**
 * Candidate Card for the Candidate record page: the structured view of one CV,
 * with missing, uncertain and conflicting data shown separately.
 */
export default class CandidateCard extends LightningElement {
    @api recordId;
    record;
    error;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredRecord({ data, error }) {
        this.record = data;
        this.error = error ? 'The candidate card could not be loaded.' : undefined;
    }

    value(field) {
        return this.record ? getFieldValue(this.record, field) : null;
    }

    get isLoaded() {
        return !!this.record;
    }

    get isLoading() {
        return !this.record && !this.error;
    }

    get name() {
        return this.value(NAME);
    }

    get title() {
        return this.value(TITLE) || 'Title not stated';
    }

    get yearsLabel() {
        const years = this.value(YEARS);
        return years === null || years === undefined ? 'Experience not stated' : `${years} years experience`;
    }

    get email() {
        return this.value(EMAIL) || 'Email not stated';
    }

    get phone() {
        return this.value(PHONE) || 'Phone not stated';
    }

    get status() {
        return this.value(STATUS) || 'Unknown';
    }

    get statusClass() {
        const theme = STATUS_THEME[this.status];
        return `status status_${theme ? theme.css : 'info'}`;
    }

    get statusHint() {
        const theme = STATUS_THEME[this.status];
        return theme ? theme.hint : '';
    }

    get skills() {
        return withKeys(toList(this.value(SKILLS), ','));
    }

    get hasSkills() {
        return this.skills.length > 0;
    }

    get missing() {
        return withKeys(toList(this.value(MISSING), ','));
    }

    get uncertain() {
        return withKeys(toList(this.value(UNCERTAIN), '\n'));
    }

    get conflicts() {
        return withKeys(toList(this.value(CONFLICTS), '\n'));
    }

    get hasMissing() {
        return this.missing.length > 0;
    }

    get hasUncertain() {
        return this.uncertain.length > 0;
    }

    get hasConflicts() {
        return this.conflicts.length > 0;
    }

    get isClean() {
        return !this.hasMissing && !this.hasUncertain && !this.hasConflicts;
    }

    get sections() {
        return [
            { key: 'exp', label: 'Experience', text: this.value(EXPERIENCE) },
            { key: 'edu', label: 'Education', text: this.value(EDUCATION) },
            { key: 'ach', label: 'Achievements', text: this.value(ACHIEVEMENTS) }
        ].map((section) => ({
            ...section,
            css: section.text ? 'text' : 'text empty',
            display: section.text || 'Not stated in the CV'
        }));
    }
}
