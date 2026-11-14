@IsTest
private class CandidateAgentActionsTest {
    @TestSetup
    static void setup() {
        System.runAs(TestUserFactory.recruiter()) {
            insert new Job_Role__c(Name = 'Salesforce Developer', Required_Skills__c = 'Apex, LWC, SOQL, Flows', Min_Years__c = 4);
            insert new Job_Role__c(Name = 'Java Backend Engineer', Required_Skills__c = 'Java, Hibernate, Docker', Min_Years__c = 3);
            insert new List<Candidate__c>{
                new Candidate__c(
                    Name = 'Omar Hassan',
                    Email__c = 'omar@example.com',
                    Title__c = 'Senior Salesforce Developer',
                    Years_of_Experience__c = 6,
                    Skills__c = 'Apex, Lightning Web Components, SOQL/SOSL, Flows',
                    Data_Status__c = 'Complete',
                    CV_Text__c = 'Omar Hassan\nSenior Salesforce Developer\nCERTIFICATIONS\nPlatform Developer II (2022)'
                ),
                new Candidate__c(
                    Name = 'Mariam Adel',
                    Title__c = 'Salesforce Developer',
                    Skills__c = 'Apex, LWC, Flows, SOQL, JavaScript',
                    Data_Status__c = 'Partial',
                    Missing_Info__c = 'Email, Phone, Years of Experience',
                    CV_Text__c = 'Mariam Adel\nSalesforce Developer\nSKILLS\nApex, LWC, Flows, SOQL, JavaScript'
                ),
                new Candidate__c(
                    Name = 'Nour Samir',
                    Title__c = 'Backend Engineer (Java)',
                    Years_of_Experience__c = 5,
                    Skills__c = 'Java, SQL, some Apex, SF, Hibernate',
                    Data_Status__c = 'Partial',
                    Uncertain_Info__c = 'Skills: "SF" is ambiguous.',
                    CV_Text__c = 'Nour Samir\nJava, SQL, some Apex'
                )
            };
        }
    }

    private static Map<String, Object> parse(String json) {
        return (Map<String, Object>) System.JSON.deserializeUntyped(json);
    }

    @IsTest
    static void searchMatchesAllKeywordsWholeWord() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            SearchCandidatesAction.Request req = new SearchCandidatesAction.Request();
            req.keywords = 'Apex, Flows';
            Map<String, Object> res = parse(SearchCandidatesAction.run(new List<SearchCandidatesAction.Request>{ req })[0].result);
            Map<String, Object> data = (Map<String, Object>) res.get('data');
            Assert.areEqual(2, data.get('totalMatches'), 'Omar and Mariam mention both Apex and Flows');

            req.keywords = 'Java';
            data = (Map<String, Object>) parse(SearchCandidatesAction.run(new List<SearchCandidatesAction.Request>{ req })[0].result).get('data');
            Assert.areEqual(1, data.get('totalMatches'), '"JavaScript" must not count as "Java"');
        }
    }

    @IsTest
    static void detailsReturnEvidenceAndReportsUnknownTerms() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            GetCandidateDetailsAction.Request req = new GetCandidateDetailsAction.Request();
            req.candidate = 'Omar Hassan';
            req.searchTerms = 'Platform Developer, AWS';
            Map<String, Object> data = (Map<String, Object>) parse(
                    GetCandidateDetailsAction.run(new List<GetCandidateDetailsAction.Request>{ req })[0].result
                )
                .get('data');

            List<Object> evidence = (List<Object>) data.get('evidence');
            Assert.areEqual(1, evidence.size());
            Assert.areEqual(4, ((Map<String, Object>) evidence[0]).get('line'));
            Assert.areEqual(new List<Object>{ 'AWS' }, (List<Object>) data.get('termsNotFoundInCv'));
        }
    }

    @IsTest
    static void unknownCandidateReturnsReadableError() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            GetCandidateDetailsAction.Request req = new GetCandidateDetailsAction.Request();
            req.candidate = 'Nobody Here';
            Map<String, Object> res = parse(GetCandidateDetailsAction.run(new List<GetCandidateDetailsAction.Request>{ req })[0].result);
            Assert.areEqual(false, res.get('success'));
            Assert.isTrue(((String) res.get('error')).contains('No candidate matches'));
        }
    }

    @IsTest
    static void scoringRanksAndExplains() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            ScoreCandidatesAction.Request req = new ScoreCandidatesAction.Request();
            req.jobRole = 'Salesforce Developer';
            Map<String, Object> data = (Map<String, Object>) parse(
                    ScoreCandidatesAction.run(new List<ScoreCandidatesAction.Request>{ req })[0].result
                )
                .get('data');

            List<Object> ranking = (List<Object>) data.get('ranking');
            Map<String, Object> first = (Map<String, Object>) ranking[0];
            Assert.areEqual('Omar Hassan', first.get('candidateName'));
            Assert.areEqual(100, first.get('score'), 'All skills (via LWC alias), years and complete data');
            Assert.isTrue(((String) data.get('recommendation')).contains('Omar Hassan'));
            // Explainability: every candidate except the last says why it beats the next one.
            String why = (String) first.get('rankedAboveNextBecause');
            Assert.isTrue(why.startsWith('Ranked '), why);
            Assert.isTrue(why.contains('points above'), why);
            Assert.isNull(((Map<String, Object>) ranking[ranking.size() - 1]).get('rankedAboveNextBecause'));
        }
        // Audit trail: the action is logged with the role it was evaluated for.
        Agent_Audit_Log__c log = [SELECT Action__c, Status__c, Job_Role__c FROM Agent_Audit_Log__c];
        Assert.areEqual('Score Candidates', log.Action__c);
        Assert.areEqual('Success', log.Status__c);
        Assert.isNotNull(log.Job_Role__c);
    }

    @IsTest
    static void tiedScoresAreExplained() {
        CandidateAgentService.ScoreResult a = new CandidateAgentService.ScoreResult();
        a.candidateName = 'A';
        a.score = 50;
        a.skillPoints = 30;
        a.experiencePoints = 12;
        a.dataQualityPoints = 8;
        CandidateAgentService.ScoreResult b = new CandidateAgentService.ScoreResult();
        b.candidateName = 'B';
        b.score = 50;
        b.skillPoints = 30;
        b.experiencePoints = 12;
        b.dataQualityPoints = 8;
        Assert.isTrue(CandidateAgentService.compare(a, b).startsWith('Tied with B'));
    }

    @IsTest
    static void failedActionIsAuditedAsError() {
        System.runAs(TestUserFactory.existingRecruiter()) {
                ScoreCandidatesAction.Request req = new ScoreCandidatesAction.Request();
                req.jobRole = 'Astronaut';
                ScoreCandidatesAction.run(new List<ScoreCandidatesAction.Request>{ req });
                // Recruiters can read the trail (permission set grants read-only access).
                Agent_Audit_Log__c log = [SELECT Status__c, Error_Message__c FROM Agent_Audit_Log__c WITH USER_MODE];
                Assert.areEqual('Error', log.Status__c);
                Assert.isTrue(log.Error_Message__c.contains('No job role matches'));
        }
    }

    @IsTest
    static void noStrongMatchSaysSoAndListsGaps() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            ScoreCandidatesAction.Request req = new ScoreCandidatesAction.Request();
            req.jobRole = 'Java Backend Engineer';
            req.candidates = 'Mariam Adel, Omar Hassan';
            Map<String, Object> data = (Map<String, Object>) parse(
                    ScoreCandidatesAction.run(new List<ScoreCandidatesAction.Request>{ req })[0].result
                )
                .get('data');
            Assert.isTrue(((String) data.get('recommendation')).startsWith('No candidate reaches'));
        }
    }

    @IsTest
    static void ambiguousAbbreviationIsNotTreatedAsSalesforce() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            Job_Role__c role = [SELECT Id, Name, Required_Skills__c, Min_Years__c FROM Job_Role__c WHERE Name = 'Salesforce Developer'];
            Candidate__c nour = CandidateAgentService.resolveCandidate('Nour Samir');
            CandidateAgentService.ScoreResult r = CandidateAgentService.score(role, nour);
            Assert.isTrue(r.missingSkills.contains('LWC'));
            Assert.isFalse(r.strongMatch);
        }
    }

    @IsTest
    static void bookmarkThenNoteThenRebookmarkUpdates() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            BookmarkCandidateAction.Request bm = new BookmarkCandidateAction.Request();
            bm.candidate = 'Omar Hassan';
            bm.jobRole = 'Salesforce Developer';
            bm.reasoning = 'Full skill coverage and senior experience.';
            Map<String, Object> data = (Map<String, Object>) parse(
                    BookmarkCandidateAction.run(new List<BookmarkCandidateAction.Request>{ bm })[0].result
                )
                .get('data');
            Assert.areEqual('created', data.get('status'));

            AddBookmarkNoteAction.Request note = new AddBookmarkNoteAction.Request();
            note.candidate = 'Omar Hassan';
            note.note = 'Schedule technical interview.';
            AddBookmarkNoteAction.run(new List<AddBookmarkNoteAction.Request>{ note });

            data = (Map<String, Object>) parse(BookmarkCandidateAction.run(new List<BookmarkCandidateAction.Request>{ bm })[0].result)
                .get('data');
            Assert.areEqual('updated existing bookmark', data.get('status'));

            Candidate_Bookmark__c saved = [SELECT Score__c, Notes__c, Reasoning__c, Candidate_Summary__c FROM Candidate_Bookmark__c];
            Assert.areEqual(100, saved.Score__c);
            Assert.isTrue(saved.Notes__c.contains('Schedule technical interview.'));
            Assert.isTrue(saved.Reasoning__c.contains('Recommendation rationale'));
            Assert.isTrue(saved.Candidate_Summary__c.contains('Omar Hassan'));
        }
    }

    @IsTest
    static void noteWithoutBookmarkFailsClearly() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            AddBookmarkNoteAction.Request note = new AddBookmarkNoteAction.Request();
            note.candidate = 'Mariam Adel';
            note.note = 'Follow up';
            Map<String, Object> res = parse(AddBookmarkNoteAction.run(new List<AddBookmarkNoteAction.Request>{ note })[0].result);
            Assert.areEqual(false, res.get('success'));
            Assert.isTrue(((String) res.get('error')).contains('has not been bookmarked'));
        }
    }

    @IsTest
    static void unknownRoleListsAvailableRoles() {
        System.runAs(TestUserFactory.existingRecruiter()) {
            ScoreCandidatesAction.Request req = new ScoreCandidatesAction.Request();
            req.jobRole = 'Astronaut';
            Map<String, Object> res = parse(ScoreCandidatesAction.run(new List<ScoreCandidatesAction.Request>{ req })[0].result);
            Assert.isTrue(((String) res.get('error')).contains('Available roles'));
        }
    }
}
