@IsTest
private class CvIngestionControllerTest {
    private static final String FULL_CV =
        'Sara Ahmed\n' +
        'sara.ahmed@example.com | +20 100 123 4567\n' +
        'Salesforce Developer with 5 years of experience\n\n' +
        'Skills\n' +
        'Apex, LWC, SOQL, Integration\n\n' +
        'Experience\n' +
        'Developer at Acme 2019 - 2024';

    @IsTest
    static void createsCandidateWithFallbackParser() {
        CvParserService.forceFallback = true;

        Test.startTest();
        CvIngestionController.IngestionResult result = CvIngestionController.processCv(
            'sara.pdf',
            FULL_CV,
            EncodingUtil.base64Encode(Blob.valueOf('fake pdf'))
        );
        Test.stopTest();

        Candidate__c saved = [
            SELECT Name, Email__c, Phone__c, Years_of_Experience__c, Skills__c, Missing_Info__c, Data_Status__c
            FROM Candidate__c
            WHERE Id = :result.candidateId
        ];
        Assert.areEqual('Sara Ahmed', saved.Name);
        Assert.areEqual('sara.ahmed@example.com', saved.Email__c);
        Assert.areEqual(5, saved.Years_of_Experience__c);
        Assert.isTrue(saved.Skills__c.contains('LWC'));
        // Fallback cannot read title/experience/education reliably - they must be flagged, not guessed.
        Assert.isTrue(saved.Missing_Info__c.contains('Title'));
        Assert.areEqual(CvIngestionController.STATUS_PARTIAL, saved.Data_Status__c);
        Assert.areEqual('Rule-based fallback', result.parsedBy);
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :result.candidateId]);
    }

    @IsTest
    static void reuploadUpdatesExistingCandidateByEmail() {
        CvParserService.forceFallback = true;
        CvIngestionController.processCv('v1.pdf', FULL_CV, null);

        CvIngestionController.IngestionResult second = CvIngestionController.processCv('v2.pdf', FULL_CV, null);

        Assert.isTrue(second.updatedExisting);
        Assert.areEqual(1, [SELECT COUNT() FROM Candidate__c]);
    }

    @IsTest
    static void conflictingEmailsMarkRecordForReview() {
        CvParserService.forceFallback = true;
        String cv = FULL_CV + '\nAlternative contact: sara.work@example.org';

        CvIngestionController.IngestionResult result = CvIngestionController.processCv('sara.pdf', cv, null);

        Assert.areEqual(CvIngestionController.STATUS_NEEDS_REVIEW, result.status);
        Assert.isFalse(result.conflicts.isEmpty());
    }

    @IsTest
    static void missingNameFallsBackToFileName() {
        CvParserService.forceFallback = true;
        String cv = 'Curriculum vitae of a backend engineer.\nWorked on many projects with Java and Spring.';

        CvIngestionController.IngestionResult result = CvIngestionController.processCv('anon.docx', cv, null);

        Assert.areEqual('Unknown - anon.docx', result.candidateName);
        Assert.isTrue(result.missingFields.contains('Email'));
        Assert.isTrue(result.missingFields.contains('Name'));
    }

    @IsTest
    static void blankTextIsRejected() {
        try {
            CvIngestionController.processCv('empty.pdf', '   ', null);
            Assert.fail('Expected an exception for blank text');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e);
        }
    }

    @IsTest
    static void hallucinatedEmailIsDiscarded() {
        ParsedCv cv = new ParsedCv();
        cv.email = 'invented@nowhere.com';
        cv.phone = '+1 555 000 0000';

        CvParserService.validateAgainstSource(cv, 'Real CV text with no contact details.');

        Assert.isNull(cv.email);
        Assert.isNull(cv.phone);
        Assert.areEqual(2, cv.conflicts.size());
    }

    @IsTest
    static void extractJsonStripsMarkdownFences() {
        String raw = 'Here you go:\n```json\n{"name":"Ali"}\n```';
        Assert.areEqual('{"name":"Ali"}', CvParserService.extractJson(raw));
    }

    @IsTest
    static void recentCandidatesReturnsRows() {
        insert new Candidate__c(Name = 'Test Person');
        Assert.areEqual(1, CvIngestionController.getRecentCandidates(5).size());
    }
}
