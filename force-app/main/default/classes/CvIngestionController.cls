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
        @AuraEnabled public Boolean updatedExisting = false;
        @AuraEnabled public String parsedBy;
    }

    @AuraEnabled
    public static IngestionResult processCv(String fileName, String cvText, String base64File) {
        try {
            ParsedCv cv = CvParserService.parse(cvText);

            Candidate__c candidate = findExisting(cv.email);
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
            result.updatedExisting = isUpdate;
            result.parsedBy = cv.parsedBy;
            return result;
        } catch (Exception e) {
            throw new AuraHandledException(fileName + ': ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<Candidate__c> getRecentCandidates(Integer limitSize) {
        Integer rows = (limitSize == null || limitSize <= 0) ? 10 : Math.min(limitSize, 50);
        return [
            SELECT Id, Name, Title__c, Years_of_Experience__c, Data_Status__c, Email__c, LastModifiedDate
            FROM Candidate__c
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT :rows
        ];
    }

    // --------------------------------------------------------------- helpers

    /** Email is the natural key: re-uploading the same person's CV updates their card. */
    private static Candidate__c findExisting(String email) {
        if (String.isBlank(email)) {
            return null;
        }
        List<Candidate__c> existing = [
            SELECT Id
            FROM Candidate__c
            WHERE Email__c = :email
            WITH USER_MODE
            LIMIT 1
        ];
        return existing.isEmpty() ? null : existing[0];
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
        rec.CV_Text__c = fit(cvText);
        rec.Data_Status__c = resolveStatus(cv);
    }

    @TestVisible
    private static String resolveStatus(ParsedCv cv) {
        if (!cv.conflicts.isEmpty()) {
            return STATUS_NEEDS_REVIEW;
        }
        return cv.missingFields.isEmpty() ? STATUS_COMPLETE : STATUS_PARTIAL;
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
