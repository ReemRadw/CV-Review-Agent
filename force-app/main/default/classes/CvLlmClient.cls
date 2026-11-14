/**
 * Abstraction over the LLM call used to structure a CV.
 * Production uses PromptTemplateCvLlmClient; tests inject a mock, so the
 * parsing, validation and fallback logic can be tested without a real model.
 */
public interface CvLlmClient {
    /** Returns the raw model response (expected to contain a JSON object). */
    String generate(String cvText);
}
