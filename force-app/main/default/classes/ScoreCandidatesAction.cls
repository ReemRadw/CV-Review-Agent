public with sharing class ScoreCandidatesAction {
    private static final Integer MAX_RANKED = 10;

    public class Request {
        @InvocableVariable(label='Job Role' description='Job role name or record Id to score candidates against.' required=true)
        public String jobRole;

        @InvocableVariable(
            label='Candidates'
            description='Optional comma-separated candidate names or Ids to compare. Leave empty to score every candidate.'
        )
        public String candidates;
    }

    public class Response {
        @InvocableVariable(label='Result' description='JSON ranking with score breakdown, strengths, concerns and a recommendation.')
        public String result;
    }

    @InvocableMethod(
        label='Score Candidates'
        description='Scores and ranks candidates against a job role using a fixed, explainable rubric: required skills (60), years of experience (25) and CV data quality (15). Returns the breakdown, strengths, concerns and whether any candidate is a strong match (70+).'
    )
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            AgentAuditLogger.Entry log = AgentAuditLogger.start('Score Candidates', req);
            try {
                Job_Role__c role = CandidateAgentService.resolveJobRole(req.jobRole);
                log.jobRoleId = role.Id;
                List<Candidate__c> pool = loadPool(req.candidates);
                if (pool.isEmpty()) {
                    throw new CandidateAgentService.AgentException('There are no candidates to score yet.');
                }

                List<CandidateAgentService.ScoreResult> ranked = CandidateAgentService.scoreAndRank(role, pool);
                List<CandidateAgentService.ScoreResult> top = new List<CandidateAgentService.ScoreResult>();
                for (Integer i = 0; i < ranked.size() && i < MAX_RANKED; i++) {
                    top.add(ranked[i]);
                }

                res.result = AgentResponse.ok(
                    new Map<String, Object>{
                        'jobRole' => new Map<String, Object>{
                            'name' => role.Name,
                            'requiredSkills' => role.Required_Skills__c,
                            'minYears' => role.Min_Years__c
                        },
                        'rubric' => 'skills 60 (share of required skills found in skills/title/experience) + experience 25 (years vs minimum) + data quality 15 (Complete 15, Partial 8, Needs Review 3)',
                        'strongMatchThreshold' => CandidateAgentService.STRONG_MATCH_THRESHOLD,
                        'candidatesScored' => ranked.size(),
                        'ranking' => top,
                        'recommendation' => recommendation(ranked)
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

    private static List<Candidate__c> loadPool(String candidateRefs) {
        List<String> refs = CandidateAgentService.splitList(candidateRefs);
        if (refs.isEmpty()) {
            return CandidateAgentService.search(new List<String>(), null, null);
        }
        List<Candidate__c> pool = new List<Candidate__c>();
        Set<Id> seen = new Set<Id>();
        for (String ref : refs) {
            Candidate__c c = CandidateAgentService.resolveCandidate(ref);
            if (seen.add(c.Id)) {
                pool.add(c);
            }
        }
        return pool;
    }

    @TestVisible
    private static String recommendation(List<CandidateAgentService.ScoreResult> ranked) {
        CandidateAgentService.ScoreResult best = ranked[0];
        if (best.strongMatch) {
            return best.candidateName + ' is the strongest match (' + best.score + '/100).';
        }
        String gaps = best.missingSkills.isEmpty() ? '' : ' Validate in interview: ' + String.join(best.missingSkills, ', ') + '.';
        return 'No candidate reaches the strong-match threshold of ' + CandidateAgentService.STRONG_MATCH_THRESHOLD +
            '. Best available option is ' + best.candidateName + ' (' + best.score + '/100).' + gaps;
    }
}
