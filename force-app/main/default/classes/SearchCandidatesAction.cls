public with sharing class SearchCandidatesAction {
    private static final Integer MAX_RESULTS = 25;

    public class Request {
        @InvocableVariable(
            label='Keywords'
            description='Comma-separated skills or terms that must ALL appear in the CV, e.g. "LWC, Apex". Leave empty to list all candidates.'
        )
        public String keywords;

        @InvocableVariable(label='Minimum Years' description='Only return candidates with at least this many years of experience.')
        public Integer minYears;

        @InvocableVariable(label='Data Status' description='Optional filter: Complete, Partial or Needs Review.')
        public String dataStatus;
    }

    public class Response {
        @InvocableVariable(label='Result' description='JSON with the matching candidates (summary cards).')
        public String result;
    }

    @InvocableMethod(
        label='Search Candidates'
        description='Finds candidates whose CV mentions all given keywords, optionally filtered by minimum years of experience or data status. Returns summary cards, not full CVs.'
    )
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            AgentAuditLogger.Entry log = AgentAuditLogger.start('Search Candidates', req);
            try {
                List<Candidate__c> found = CandidateAgentService.search(
                    CandidateAgentService.splitList(req.keywords),
                    req.minYears,
                    req.dataStatus
                );
                List<Map<String, Object>> cards = new List<Map<String, Object>>();
                for (Integer i = 0; i < found.size() && i < MAX_RESULTS; i++) {
                    cards.add(AgentResponse.summary(found[i]));
                }
                res.result = AgentResponse.ok(
                    new Map<String, Object>{
                        'totalMatches' => found.size(),
                        'returned' => cards.size(),
                        'candidates' => cards
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
}
