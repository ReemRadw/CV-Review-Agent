/**
 * Server side of the cvUploader LWC.
 * The browser extracts text from PDF/DOCX, this class structures it,
 * stores the Candidate Card and attaches the original file.
 */
public with sharing class CvIngestionController {
    private static final Integer LONG_TEXT_LIMIT = 32768;

    public static final String STATUS_COMPLETE = 'Complete';
    public static final String STATUS_PARTIAL = 'Partial';
    public static final String STATUS_NEEDS_REVIEW = 'Needs Review';

    public class IngestionResult {
        @AuraEnabled public Id candidateId;
        @AuraEnabled public String candidateName;
        @AuraEnabled public String title;
        @AuraEnabled public Integer yearsOfExperience;
        @AuraEnabled public List<String> skills;
        @AuraEnabled public String status;
        @AuraEnabled public List<String> missingFields;
        @AuraEnabled public List<String> conflicts;
        @AuraEnabled public List<String> uncertainties;
        @AuraEnabled public Boolean updatedExisting = false;
        @AuraEnabled public String parsedBy;
        /** Set instead of throwing, so the failure can be audit-logged (a throw would roll the log back). */
        @AuraEnabled public String errorMessage;
    }

    @AuraEnabled
    public static IngestionResult processCv(String fileName, String cvText, String base64File) {
        AgentAuditLogger.Entry log = AgentAuditLogger.start(
            'CV Ingestion',
            new Map<String, Object>{
                'fileName' => fileName,
                'textLength' => cvText == null ? 0 : cvText.length(),
                'fileAttached' => String.isNotBlank(base64File)
            }
        );
        Savepoint sp;
        try {
            // The LLM call must happen before any DML (no callouts after uncommitted work).
            ParsedCv cv = CvParserService.parse(cvText);
            sp = Database.setSavepoint();

            Candidate__c candidate = findExisting(cv);
            Boolean isUpdate = candidate != null;
            if (!isUpdate) {
                candidate = new Candidate__c();
            }
            mapToRecord(cv, candidate, cvText, fileName);
            upsert as user candidate;

            if (String.isNotBlank(base64File)) {
                attachFile(candidate.Id, fileName, base64File);
            }

            IngestionResult result = new IngestionResult();
            result.candidateId = candidate.Id;
            result.candidateName = candidate.Name;
            result.title = cv.title;
            result.yearsOfExperience = cv.yearsOfExperience;
            result.skills = cv.skills;
            result.status = candidate.Data_Status__c;
            result.missingFields = cv.missingFields;
            result.conflicts = cv.conflicts;
            result.uncertainties = cv.uncertainties;
            result.updatedExisting = isUpdate;
            result.parsedBy = cv.parsedBy;

            log.candidateId = candidate.Id;
            AgentAuditLogger.success(
                log,
                JSON.serialize(
                    new Map<String, Object>{
                        'candidate' => candidate.Name,
                        'dataStatus' => candidate.Data_Status__c,
                        'parsedBy' => cv.parsedBy,
                        'fallbackReason' => cv.fallbackReason,
                        'updatedExisting' => isUpdate,
                        'missingFields' => cv.missingFields,
                        'uncertainties' => cv.uncertainties,
                        'conflicts' => cv.conflicts
                    },
                    true
                )
            );
            AgentAuditLogger.flush();
            return result;
        } catch (Exception e) {
            if (sp != null) {
                Database.rollback(sp); // no half-saved candidate without its file
            }
            AgentAuditLogger.failure(log, e.getTypeName() + ': ' + e.getMessage());
            AgentAuditLogger.flush();

            IngestionResult failed = new IngestionResult();
            failed.errorMessage = friendlyError(e);
            return failed;
        }
    }

    /** Recruiter-facing message; technical detail stays in the audit log. */
    private static String friendlyError(Exception e) {
        if (e instanceof CvParserService.CvParseException) {
            return e.getMessage();
        }
        if (e instanceof DmlException && e.getMessage().contains('DUPLICATE_VALUE')) {
            return 'A candidate with this email already exists and could not be updated.';
        }
        return 'The CV could not be saved. Details were recorded in the Agent Audit Log.';
    }

    @AuraEnabled(cacheable=false)
    public static List<Candidate__c> getRecentCandidates(Integer limitSize) {
        Integer rows = (limitSize == null || limitSize <= 0) ? 10 : Math.min(limitSize, 50);
        return [
            SELECT Id, Name, Title__c, Years_of_Experience__c, Data_Status__c, LastModifiedDate
            FROM Candidate__c
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT :rows
        ];
    }

    // --------------------------------------------------------------- helpers

    /**
     * Re-uploading the same person's CV updates their card instead of duplicating it.
     * Email is the natural key. Without an email we fall back to an exact name match
     * among candidates that also have no email, and say so on the card.
     */
    @TestVisible
    private static Candidate__c findExisting(ParsedCv cv) {
        if (String.isNotBlank(cv.email)) {
            List<Candidate__c> byEmail = [SELECT Id FROM Candidate__c WHERE Email__c = :cv.email WITH USER_MODE LIMIT 1];
            return byEmail.isEmpty() ? null : byEmail[0];
        }
        if (String.isBlank(cv.name)) {
            return null;
        }
        List<Candidate__c> byName = [
            SELECT Id
            FROM Candidate__c
            WHERE Name = :cv.name AND Email__c = NULL
            WITH USER_MODE
            LIMIT 2
        ];
        if (byName.size() == 1) {
            cv.uncertainties.add(
                'Identity: the CV has no email address, so it was matched to the existing candidate with the same name. Please confirm it is the same person.'
            );
            return byName[0];
        }
        if (byName.size() > 1) {
            cv.uncertainties.add(
                'Identity: the CV has no email address and several existing candidates share this name, so a new card was created.'
            );
        }
        return null;
    }

    @TestVisible
    private static void mapToRecord(ParsedCv cv, Candidate__c rec, String cvText, String fileName) {
        // Name is required on the object; keep the file name visible rather than inventing one.
        rec.Name = String.isNotBlank(cv.name) ? cv.name.abbreviate(80) : ('Unknown - ' + fileName).abbreviate(80);
        rec.Email__c = cv.email;
        rec.Phone__c = cv.phone;
        rec.Title__c = cv.title == null ? null : cv.title.abbreviate(100);
        rec.Years_of_Experience__c = cv.yearsOfExperience;
        rec.Skills__c = cv.skills.isEmpty() ? null : String.join(cv.skills, ', ');
        rec.Experience__c = fit(formatExperience(cv.experience));
        rec.Education__c = fit(formatEducation(cv.education));
        rec.Achievements__c = cv.achievements.isEmpty() ? null : fit('• ' + String.join(cv.achievements, '\n• '));
        rec.Missing_Info__c = cv.missingFields.isEmpty() ? null : String.join(cv.missingFields, ', ');
        rec.Conflicts__c = cv.conflicts.isEmpty() ? null : fit('• ' + String.join(cv.conflicts, '\n• '));
        rec.Uncertain_Info__c = cv.uncertainties.isEmpty() ? null : fit('• ' + String.join(cv.uncertainties, '\n• '));
        rec.CV_Text__c = fit(cvText);
        rec.Data_Status__c = resolveStatus(cv);
    }

    @TestVisible
    private static String resolveStatus(ParsedCv cv) {
        if (!cv.conflicts.isEmpty()) {
            return STATUS_NEEDS_REVIEW;
        }
        // Missing or uncertain data still produces a usable card, but not a "Complete" one.
        return (cv.missingFields.isEmpty() && cv.uncertainties.isEmpty()) ? STATUS_COMPLETE : STATUS_PARTIAL;
    }

    private static String formatExperience(List<ParsedCv.ExperienceItem> items) {
        if (items.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        for (ParsedCv.ExperienceItem item : items) {
            String header = joinNonBlank(new List<String>{ item.role, item.company, item.period }, ' | ');
            lines.add(String.isBlank(item.summary) ? header : header + '\n  ' + item.summary);
        }
        return String.join(lines, '\n');
    }

    private static String formatEducation(List<ParsedCv.EducationItem> items) {
        if (items.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        for (ParsedCv.EducationItem item : items) {
            lines.add(joinNonBlank(new List<String>{ item.degree, item.institution, item.year }, ' | '));
        }
        return String.join(lines, '\n');
    }

    private static String joinNonBlank(List<String> parts, String separator) {
        List<String> kept = new List<String>();
        for (String part : parts) {
            if (String.isNotBlank(part)) {
                kept.add(part.trim());
            }
        }
        return String.join(kept, separator);
    }

    private static String fit(String value) {
        return value == null ? null : value.abbreviate(LONG_TEXT_LIMIT);
    }

    private static void attachFile(Id recordId, String fileName, String base64File) {
        ContentVersion version = new ContentVersion(
            Title = fileName,
            PathOnClient = fileName,
            VersionData = EncodingUtil.base64Decode(base64File),
            FirstPublishLocationId = recordId
        );
        insert as user version;
    }
}
