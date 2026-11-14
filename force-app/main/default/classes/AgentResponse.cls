/**
 * Common JSON envelope returned by every agent action.
 * Errors are returned as data (success=false) instead of thrown, so the agent
 * can explain the problem to the recruiter rather than failing silently.
 */
public with sharing class AgentResponse {
    public static String ok(Object data) {
        return JSON.serializePretty(new Map<String, Object>{ 'success' => true, 'data' => data }, true);
    }

    public static String error(String message) {
        return JSON.serializePretty(new Map<String, Object>{ 'success' => false, 'error' => message }, true);
    }

    public static String error(Exception e) {
        if (e instanceof CandidateAgentService.AgentException) {
            return error(e.getMessage());
        }
        System.debug(LoggingLevel.ERROR, e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
        return error('Unexpected error: ' + e.getMessage());
    }

    /** Compact card used in lists, so the agent is not flooded with full CV text. */
    public static Map<String, Object> summary(Candidate__c c) {
        return new Map<String, Object>{
            'id' => c.Id,
            'name' => c.Name,
            'title' => c.Title__c,
            'yearsOfExperience' => c.Years_of_Experience__c,
            'skills' => c.Skills__c,
            'dataStatus' => c.Data_Status__c,
            'missingInfo' => c.Missing_Info__c,
            'hasUncertainInfo' => String.isNotBlank(c.Uncertain_Info__c),
            'hasConflicts' => String.isNotBlank(c.Conflicts__c)
        };
    }
}
