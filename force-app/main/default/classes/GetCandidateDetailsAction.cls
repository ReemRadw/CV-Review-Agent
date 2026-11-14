public with sharing class GetCandidateDetailsAction {
    private static final Integer MAX_EVIDENCE_LINES = 8;

    public class Request {
        @InvocableVariable(label='Candidate' description='Candidate name or record Id.' required=true)
        public String candidate;

        @InvocableVariable(
            label='Search Terms'
            description='Comma-separated terms related to the recruiter question (e.g. "certification, PD1"). The action returns the CV lines that mention them so the answer can be cited.'
        )
        public String searchTerms;
    }

    public class Response {
        @InvocableVariable(label='Result' description='JSON with the candidate card and CV evidence lines (line number + exact text).')
        public String result;
    }

    @InvocableMethod(
        label='Get Candidate Details'
        description='Returns the structured candidate card plus exact lines from the original CV that mention the search terms, with line numbers for citation. If no line mentions a term, it is reported as not found in the CV.'
    )
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            AgentAuditLogger.Entry log = AgentAuditLogger.start('Get Candidate Details', req);
            try {
                Candidate__c c = CandidateAgentService.resolveCandidate(req.candidate);
                log.candidateId = c.Id;
                List<String> terms = CandidateAgentService.splitList(req.searchTerms);
                List<CandidateAgentService.Evidence> evidence = CandidateAgentService.findEvidence(c, terms, MAX_EVIDENCE_LINES);

                List<String> notFound = new List<String>();
                for (String term : terms) {
                    if (!CandidateAgentService.containsTerm(c.CV_Text__c, term)) {
                        notFound.add(term);
                    }
                }

                Map<String, Object> data = AgentResponse.summary(c);
                data.put('email', c.Email__c);
                data.put('phone', c.Phone__c);
                data.put('experience', c.Experience__c);
                data.put('education', c.Education__c);
                data.put('achievements', c.Achievements__c);
                data.put('uncertainInfo', c.Uncertain_Info__c);
                data.put('conflicts', c.Conflicts__c);
                data.put('evidence', evidence);
                data.put('termsNotFoundInCv', notFound);
                data.put('source', 'CV of ' + c.Name + ' (record ' + c.Id + ')');
                res.result = AgentResponse.ok(data);
            } catch (Exception e) {
                res.result = AgentResponse.error(e);
            }
            AgentAuditLogger.fromAgentResponse(log, res.result);
            responses.add(res);
        }
        AgentAuditLogger.flush();
        return responses;
    }
}
