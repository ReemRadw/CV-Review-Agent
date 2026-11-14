public with sharing class BookmarkCandidateAction {
    public class Request {
        @InvocableVariable(label='Candidate' description='Candidate name or record Id.' required=true)
        public String candidate;

        @InvocableVariable(label='Job Role' description='Job role the candidate was evaluated for (name or Id).' required=true)
        public String jobRole;

        @InvocableVariable(label='Reasoning' description='Short rationale for the recommendation, based on the scoring results.')
        public String reasoning;

        @InvocableVariable(label='Notes' description='Optional recruiter notes to save with the bookmark.')
        public String notes;
    }

    public class Response {
        @InvocableVariable(label='Result' description='JSON with the bookmark Id, score and whether it was created or updated.')
        public String result;
    }

    @InvocableMethod(
        label='Bookmark Candidate'
        description='Saves the candidate as a bookmark for a job role with a candidate overview, the computed score and reasoning, and optional notes. Only call after the recruiter confirms. If a bookmark for the same candidate and role exists, it is updated.'
    )
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            AgentAuditLogger.Entry log = AgentAuditLogger.start('Bookmark Candidate', req);
            try {
                Candidate__c c = CandidateAgentService.resolveCandidate(req.candidate);
                Job_Role__c role = CandidateAgentService.resolveJobRole(req.jobRole);
                log.candidateId = c.Id;
                log.jobRoleId = role.Id;
                // Score is always recomputed server-side so the stored number is never made up.
                CandidateAgentService.ScoreResult score = CandidateAgentService.score(role, c);

                List<Candidate_Bookmark__c> existing = [
                    SELECT Id, Notes__c
                    FROM Candidate_Bookmark__c
                    WHERE Candidate__c = :c.Id AND Job_Role__c = :role.Id
                    WITH USER_MODE
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ];
                Boolean isUpdate = !existing.isEmpty();
                Candidate_Bookmark__c bookmark = isUpdate ? existing[0] : new Candidate_Bookmark__c(Candidate__c = c.Id, Job_Role__c = role.Id);

                bookmark.Name = (c.Name + ' - ' + role.Name).abbreviate(80);
                bookmark.Score__c = score.score;
                bookmark.Candidate_Summary__c = buildSummary(c);
                bookmark.Reasoning__c = buildReasoning(score, req.reasoning);
                if (String.isNotBlank(req.notes)) {
                    bookmark.Notes__c = BookmarkNotes.append(bookmark.Notes__c, req.notes);
                }
                upsert as user bookmark;

                res.result = AgentResponse.ok(
                    new Map<String, Object>{
                        'bookmarkId' => bookmark.Id,
                        'status' => isUpdate ? 'updated existing bookmark' : 'created',
                        'candidate' => c.Name,
                        'jobRole' => role.Name,
                        'score' => score.score
                    }
                );
            } catch (Exception e) {
                res.result = AgentResponse.error(e);
            }
            AgentAuditLogger.fromAgentResponse(log, res.result);
            responses.add(res);
        }
        AgentAuditLogger.flush();
        return responses;
    }

    @TestVisible
    private static String buildSummary(Candidate__c c) {
        List<String> lines = new List<String>{
            'Name: ' + c.Name,
            'Title: ' + valueOrNotStated(c.Title__c),
            'Years of experience: ' + (c.Years_of_Experience__c == null ? 'Not stated' : String.valueOf(c.Years_of_Experience__c)),
            'Skills: ' + valueOrNotStated(c.Skills__c),
            'Email: ' + valueOrNotStated(c.Email__c),
            'Data status: ' + valueOrNotStated(c.Data_Status__c)
        };
        if (String.isNotBlank(c.Missing_Info__c)) {
            lines.add('Missing: ' + c.Missing_Info__c);
        }
        return String.join(lines, '\n');
    }

    private static String buildReasoning(CandidateAgentService.ScoreResult score, String agentReasoning) {
        List<String> lines = new List<String>{ score.explanation };
        for (String s : score.strengths) {
            lines.add('+ ' + s);
        }
        for (String s : score.concerns) {
            lines.add('- ' + s);
        }
        if (String.isNotBlank(agentReasoning)) {
            lines.add('\nRecommendation rationale: ' + agentReasoning.trim());
        }
        return String.join(lines, '\n').abbreviate(32768);
    }

    private static String valueOrNotStated(String value) {
        return String.isBlank(value) ? 'Not stated' : value;
    }
}
