/** Calls the CV_Parser Prompt Builder template through the Einstein LLM Connect API. */
public with sharing class PromptTemplateCvLlmClient implements CvLlmClient {
    public static final String PROMPT_TEMPLATE = 'CV_Parser';
    private static final Integer MAX_PROMPT_CHARS = 30000;

    public String generate(String cvText) {
        ConnectApi.WrappedValue textValue = new ConnectApi.WrappedValue();
        textValue.value = cvText.abbreviate(MAX_PROMPT_CHARS);

        // The model needs "today" to resolve "Present" in date ranges.
        ConnectApi.WrappedValue dateValue = new ConnectApi.WrappedValue();
        dateValue.value = String.valueOf(Date.today());

        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{
            'Input:CV_Text' => textValue,
            'Input:Reference_Date' => dateValue
        };
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
            PROMPT_TEMPLATE,
            input
        );
        if (output.generations == null || output.generations.isEmpty()) {
            throw new CvParserService.CvParseException('The prompt template returned no generations.');
        }
        return output.generations[0].text;
    }
}
