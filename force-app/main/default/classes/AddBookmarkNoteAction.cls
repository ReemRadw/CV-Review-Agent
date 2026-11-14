public with sharing class AddBookmarkNoteAction {
    public class Request {
        @InvocableVariable(label='Candidate' description='Candidate name or record Id of the bookmarked candidate.' required=true)
        public String candidate;

        @InvocableVariable(label='Job Role' description='Optional job role name or Id, to pick the right bookmark if there are several.')
        public String jobRole;

        @InvocableVariable(label='Note' description='The note text exactly as the recruiter wants it saved.' required=true)
        public String note;
    }

    public class Response {
        @InvocableVariable(label='Result' description='JSON confirming which bookmark received the note.')
        public String result;
    }

    @InvocableMethod(
        label='Add Bookmark Note'
        description='Appends a timestamped recruiter note to an existing candidate bookmark. Fails clearly if the candidate has not been bookmarked yet.'
    )
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            AgentAuditLogger.Entry log = AgentAuditLogger.start('Add Bookmark Note', req);
            try {
                if (String.isBlank(req.note)) {
                    throw new CandidateAgentService.AgentException('The note is empty.');
                }
                Candidate__c c = CandidateAgentService.resolveCandidate(req.candidate);
                Id roleId = String.isBlank(req.jobRole) ? null : CandidateAgentService.resolveJobRole(req.jobRole).Id;
                log.candidateId = c.Id;
                log.jobRoleId = roleId;

                List<Candidate_Bookmark__c> bookmarks = roleId == null
                    ? [SELECT Id, Name, Notes__c FROM Candidate_Bookmark__c WHERE Candidate__c = :c.Id WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 2]
                    : [SELECT Id, Name, Notes__c FROM Candidate_Bookmark__c WHERE Candidate__c = :c.Id AND Job_Role__c = :roleId WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 1];

                if (bookmarks.isEmpty()) {
                    throw new CandidateAgentService.AgentException(c.Name + ' has not been bookmarked yet. Bookmark the candidate first.');
                }
                if (bookmarks.size() > 1) {
                    throw new CandidateAgentService.AgentException(
                        c.Name + ' is bookmarked for more than one role. Please specify the job role.'
                    );
                }

                Candidate_Bookmark__c bookmark = bookmarks[0];
                bookmark.Notes__c = BookmarkNotes.append(bookmark.Notes__c, req.note);
                update as user bookmark;

                res.result = AgentResponse.ok(
                    new Map<String, Object>{ 'bookmarkId' => bookmark.Id, 'bookmark' => bookmark.Name, 'noteSaved' => true }
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
