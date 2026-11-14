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

    /** What a well-behaved model returns for FULL_CV, wrapped in markdown like real models often do. */
    private static final String LLM_RESPONSE =
        'Here is the profile:\n```json\n{' +
        '"name":"Sara Ahmed","email":"sara.ahmed@example.com","phone":"+20 100 123 4567",' +
        '"title":"Salesforce Developer","statedYearsOfExperience":5,"computedYearsOfExperience":5,' +
        '"skills":["Apex","LWC","SOQL","Integration"],' +
        '"experience":[{"role":"Developer","company":"Acme","period":"2019 - 2024","summary":null}],' +
        '"education":null,"achievements":[],' +
        '"uncertainties":["Experience: the role summary is not described."],"conflicts":[]' +
        '}\n```';

    @TestSetup
    static void setup() {
        TestUserFactory.recruiter();
    }

    private static Agent_Audit_Log__c latestLog() {
        return [
            SELECT Action__c, Status__c, Output__c, Error_Message__c, Candidate__c
            FROM Agent_Audit_Log__c
            ORDER BY CreatedDate DESC, Name DESC
            LIMIT 1
        ];
    }

    // ------------------------------------------------------------ LLM path (mocked)

    @IsTest
    static void llmResponseIsParsedFromMarkdownAndSaved() {
        CvLlmMock mock = CvLlmMock.returning(LLM_RESPONSE);
        CvParserService.llm = mock;
        System.runAs(TestUserFactory.existingRecruiter()) {
            Test.startTest();
            CvIngestionController.IngestionResult result = CvIngestionController.processCv(
                'sara.pdf',
                FULL_CV,
                EncodingUtil.base64Encode(Blob.valueOf('fake pdf'))
            );
            Test.stopTest();

            Assert.isNull(result.errorMessage);
            Assert.areEqual(1, mock.calls);
            Assert.areEqual(CvParserService.PARSED_BY_LLM, result.parsedBy);

            Candidate__c saved = [
                SELECT Name, Email__c, Title__c, Years_of_Experience__c, Education__c, Missing_Info__c, Uncertain_Info__c, Data_Status__c
                FROM Candidate__c
                WHERE Id = :result.candidateId
            ];
            Assert.areEqual('Salesforce Developer', saved.Title__c);
            Assert.areEqual(5, saved.Years_of_Experience__c);
            Assert.isNull(saved.Education__c, 'Null from the model must stay null');
            Assert.isTrue(saved.Missing_Info__c.contains('Education'));
            Assert.isTrue(saved.Uncertain_Info__c.contains('role summary'));
            Assert.areEqual(CvIngestionController.STATUS_PARTIAL, saved.Data_Status__c);
            Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :result.candidateId]);
        }
        Agent_Audit_Log__c log = latestLog();
        Assert.areEqual('CV Ingestion', log.Action__c);
        Assert.areEqual('Success', log.Status__c);
        Assert.isNotNull(log.Candidate__c);
    }

    @IsTest
    static void hallucinatedContactDetailsFromLlmAreDiscarded() {
        CvParserService.llm = CvLlmMock.returning(
            '{"name":"Sara Ahmed","email":"sara@invented.com","phone":"+1 999 888 7777","skills":["Apex"]}'
        );
        ParsedCv cv = CvParserService.parse(FULL_CV);

        Assert.isNull(cv.email, 'Email not present in the CV must not be saved');
        Assert.isNull(cv.phone, 'Phone not present in the CV must not be saved');
        Assert.areEqual(2, cv.conflicts.size());
        Assert.isTrue(cv.conflicts[0].startsWith('Email:'));
    }

    @IsTest
    static void statedYearsThatContradictDatesBecomeAConflict() {
        CvParserService.llm = CvLlmMock.returning(
            '{"name":"Sara Ahmed","statedYearsOfExperience":10,"computedYearsOfExperience":5,"skills":["Apex"]}'
        );
        ParsedCv cv = CvParserService.parse(FULL_CV);

        Assert.areEqual(10, cv.yearsOfExperience, 'The stated value is kept, not silently replaced');
        Assert.isTrue(cv.conflicts[0].contains('states 10 years'));
    }

    @IsTest
    static void nonJsonModelResponseFallsBackToRules() {
        CvParserService.llm = CvLlmMock.returning('Sorry, I cannot help with that.');
        ParsedCv cv = CvParserService.parse(FULL_CV);

        Assert.areEqual(CvParserService.PARSED_BY_RULES, cv.parsedBy);
        Assert.isTrue(cv.fallbackReason.contains('JSON'));
        Assert.areEqual('sara.ahmed@example.com', cv.email, 'Fallback still extracts reliable fields');
    }

    // ------------------------------------------------------------ fallback path

    @IsTest
    static void realClientFailureInTestContextFallsBack() {
        // No mock: Einstein is not callable from tests, which exercises the real client's failure path.
        ParsedCv cv = CvParserService.parse(FULL_CV);
        Assert.areEqual(CvParserService.PARSED_BY_RULES, cv.parsedBy);
        Assert.isNotNull(cv.fallbackReason);
    }

    @IsTest
    static void llmOutageStillCreatesCandidateWithRules() {
        CvParserService.llm = CvLlmMock.failing();
        System.runAs(TestUserFactory.existingRecruiter()) {
            CvIngestionController.IngestionResult result = CvIngestionController.processCv('sara.pdf', FULL_CV, null);

            Candidate__c saved = [
                SELECT Name, Email__c, Years_of_Experience__c, Skills__c, Missing_Info__c, Uncertain_Info__c, Data_Status__c
                FROM Candidate__c
                WHERE Id = :result.candidateId
            ];
            Assert.areEqual('Sara Ahmed', saved.Name);
            Assert.areEqual(5, saved.Years_of_Experience__c);
            Assert.isTrue(saved.Skills__c.contains('LWC'));
            // The fallback cannot read title/experience/education reliably - flagged, not guessed.
            Assert.isTrue(saved.Missing_Info__c.contains('Title'));
            Assert.isTrue(saved.Uncertain_Info__c.contains('Years of experience'));
            Assert.areEqual(CvParserService.PARSED_BY_RULES, result.parsedBy);
        }
        Assert.isTrue(latestLog().Output__c.contains('Simulated Einstein outage'), 'Fallback reason is audited');
    }

    @IsTest
    static void reuploadUpdatesExistingCandidateByEmail() {
        CvParserService.llm = CvLlmMock.failing();
        System.runAs(TestUserFactory.existingRecruiter()) {
            CvIngestionController.processCv('v1.pdf', FULL_CV, null);
            CvIngestionController.IngestionResult second = CvIngestionController.processCv('v2.pdf', FULL_CV, null);

            Assert.isTrue(second.updatedExisting);
            Assert.areEqual(1, [SELECT COUNT() FROM Candidate__c]);
        }
    }

    @IsTest
    static void reuploadWithoutEmailMatchesByNameAndSaysSo() {
        CvParserService.llm = CvLlmMock.returning('{"name":"Mariam Adel","title":"Salesforce Developer","skills":["Apex"]}');
        System.runAs(TestUserFactory.existingRecruiter()) {
            String cv = 'Mariam Adel\nSalesforce Developer\nSkills: Apex';
            CvIngestionController.processCv('mariam_v1.pdf', cv, null);
            CvIngestionController.IngestionResult second = CvIngestionController.processCv('mariam_v2.pdf', cv, null);

            Assert.isTrue(second.updatedExisting);
            Assert.areEqual(1, [SELECT COUNT() FROM Candidate__c]);
            Assert.isTrue(second.uncertainties[0].startsWith('Identity:'));
        }
    }

    @IsTest
    static void conflictingEmailsMarkRecordForReview() {
        CvParserService.llm = CvLlmMock.failing();
        System.runAs(TestUserFactory.existingRecruiter()) {
            String cv = FULL_CV + '\nAlternative contact: sara.work@example.org';
            CvIngestionController.IngestionResult result = CvIngestionController.processCv('sara.pdf', cv, null);

            Assert.areEqual(CvIngestionController.STATUS_NEEDS_REVIEW, result.status);
            Assert.isTrue(result.conflicts[0].startsWith('Email:'));
        }
    }

    @IsTest
    static void missingNameFallsBackToFileName() {
        CvParserService.llm = CvLlmMock.failing();
        System.runAs(TestUserFactory.existingRecruiter()) {
            String cv = 'Curriculum vitae of a backend engineer.\nWorked on many projects with Java and Spring.';
            CvIngestionController.IngestionResult result = CvIngestionController.processCv('anon.docx', cv, null);

            Assert.areEqual('Unknown - anon.docx', result.candidateName);
            Assert.isTrue(result.missingFields.contains('Email'));
            Assert.isTrue(result.missingFields.contains('Name'));
        }
    }

    @IsTest
    static void blankTextReturnsErrorAndIsAudited() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            CvIngestionController.IngestionResult result = CvIngestionController.processCv('empty.pdf', '   ', null);
            Assert.areEqual('The file contains no readable text.', result.errorMessage);
            Assert.isNull(result.candidateId);
            Assert.areEqual(0, [SELECT COUNT() FROM Candidate__c]);
        }
        Agent_Audit_Log__c log = latestLog();
        Assert.areEqual('Error', log.Status__c);
        Assert.isTrue(log.Error_Message__c.contains('no readable text'));
    }

    // ------------------------------------------------------------ unit checks

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
    static void statedYearsThatContradictDatesAreAConflict() {
        ParsedCv cv = new ParsedCv().normalize();
        cv.statedYearsOfExperience = 6;
        cv.computedYearsOfExperience = 8;
        CvParserService.reconcileYears(cv);
        Assert.areEqual(6, cv.yearsOfExperience, 'The stated value is kept');
        Assert.isTrue(cv.conflicts[0].contains('states 6 years'));

        ParsedCv onlyDates = new ParsedCv().normalize();
        onlyDates.computedYearsOfExperience = 4;
        CvParserService.reconcileYears(onlyDates);
        Assert.areEqual(4, onlyDates.yearsOfExperience);
        Assert.isTrue(onlyDates.uncertainties[0].contains('estimated as 4'));
    }

    @IsTest
    static void extractJsonStripsMarkdownFences() {
        String raw = 'Here you go:\n```json\n{"name":"Ali"}\n```';
        Assert.areEqual('{"name":"Ali"}', CvParserService.extractJson(raw));
    }

    @IsTest
    static void recentCandidatesReturnsRows() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            insert new Candidate__c(Name = 'Test Person');
            Assert.areEqual(1, CvIngestionController.getRecentCandidates(5).size());
        }
    }
}
