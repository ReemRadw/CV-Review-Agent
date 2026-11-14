/**
 * Records every agent action and CV ingestion in Agent_Audit_Log__c.
 *
 * Logs are inserted in SYSTEM_MODE on purpose: recruiters get read-only access
 * through the permission set, so they can review the trail but not edit it.
 * Logging must never break the business operation, so failures are swallowed
 * and written to the debug log instead.
 */
public without sharing class AgentAuditLogger {
    private static final Integer TEXT_LIMIT = 32768;

    public class Entry {
        public String action;
        public Long startedAt = System.currentTimeMillis();
        public Object input;
        public String output;
        public String errorMessage;
        public Id candidateId;
        public Id jobRoleId;

        public Entry(String action, Object input) {
            this.action = action;
            this.input = input;
        }
    }

    public static Entry start(String action, Object input) {
        return new Entry(action, input);
    }

    /** Records a successful step. */
    public static void success(Entry entry, String output) {
        entry.output = output;
        write(entry, 'Success');
    }

    /** Records a failed step with its error message. */
    public static void failure(Entry entry, String errorMessage) {
        entry.errorMessage = errorMessage;
        write(entry, 'Error');
    }

    /** Agent actions return {success:false,...} instead of throwing - log them as errors. */
    public static void fromAgentResponse(Entry entry, String responseJson) {
        entry.output = responseJson;
        Map<String, Object> parsed = parse(responseJson);
        Boolean ok = parsed != null && parsed.get('success') == true;
        if (!ok) {
            entry.errorMessage = parsed == null ? 'Unreadable action response' : (String) parsed.get('error');
        }
        write(entry, ok ? 'Success' : 'Error');
    }

    /** Entries are buffered so bulk invocations write all logs with a single DML. */
    private static List<Agent_Audit_Log__c> pending = new List<Agent_Audit_Log__c>();

    private static void write(Entry entry, String status) {
        pending.add(
            new Agent_Audit_Log__c(
                Action__c = entry.action.abbreviate(80),
                Status__c = status,
                Input__c = truncate(entry.input == null ? null : JSON.serialize(entry.input, true)),
                Output__c = truncate(entry.output),
                Error_Message__c = truncate(entry.errorMessage),
                Candidate__c = entry.candidateId,
                Job_Role__c = entry.jobRoleId,
                Duration_Ms__c = System.currentTimeMillis() - entry.startedAt
            )
        );
    }

    /** Persists buffered entries. Call once at the end of the transaction's entry point. */
    public static void flush() {
        if (pending.isEmpty()) {
            return;
        }
        try {
            Database.insert(pending, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Audit log could not be written: ' + e.getMessage());
        }
        pending.clear();
    }

    private static Map<String, Object> parse(String responseJson) {
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(responseJson);
        } catch (Exception e) {
            return null;
        }
    }

    private static String truncate(String value) {
        return value == null ? null : value.abbreviate(TEXT_LIMIT);
    }
}
