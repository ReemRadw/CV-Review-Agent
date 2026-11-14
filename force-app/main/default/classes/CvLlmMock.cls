/** Test double for the LLM: returns a canned response or simulates an outage. */
@IsTest
public class CvLlmMock implements CvLlmClient {
    private final String response;
    private final Boolean fail;
    public Integer calls = 0;

    private CvLlmMock(String response, Boolean fail) {
        this.response = response;
        this.fail = fail;
    }

    public static CvLlmMock returning(String response) {
        return new CvLlmMock(response, false);
    }

    /** Simulates the model or Einstein service being unavailable. */
    public static CvLlmMock failing() {
        return new CvLlmMock(null, true);
    }

    public String generate(String cvText) {
        calls++;
        if (fail) {
            throw new CalloutException('Simulated Einstein outage');
        }
        return response;
    }
}
