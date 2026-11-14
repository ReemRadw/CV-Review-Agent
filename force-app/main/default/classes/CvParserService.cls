/**
 * Turns raw CV text into a ParsedCv.
 *
 * Primary path : Prompt Builder Flex template (CV_Parser) returning strict JSON.
 * Fallback path: deterministic regex extraction for the fields that can be
 *                found reliably (email, phone, name, skills section), so an
 *                upload never fails just because the LLM is unavailable.
 *
 * After either path, the result is validated against the source text:
 * values that cannot be found in the CV are dropped and flagged.
 */
public with sharing class CvParserService {
    public static final String PARSED_BY_LLM = 'Prompt Template';
    public static final String PARSED_BY_RULES = 'Rule-based fallback';

    /** Swappable so unit tests can mock the model (see CvLlmMock). */
    @TestVisible
    private static CvLlmClient llm = new PromptTemplateCvLlmClient();

    private static final Pattern EMAIL_PATTERN = Pattern.compile(
        '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}'
    );
    private static final Pattern PHONE_PATTERN = Pattern.compile(
        '(\\+?\\d[\\d\\s().-]{7,}\\d)'
    );
    private static final Pattern YEARS_PATTERN = Pattern.compile(
        '(?i)(\\d{1,2})\\+?\\s*(?:years|yrs)'
    );

    public static ParsedCv parse(String cvText) {
        if (String.isBlank(cvText)) {
            throw new CvParseException('The file contains no readable text.');
        }

        ParsedCv result;
        String fallbackReason;
        try {
            result = parseWithLlm(cvText);
            result.parsedBy = PARSED_BY_LLM;
        } catch (Exception e) {
            fallbackReason = e.getTypeName() + ': ' + e.getMessage();
            System.debug(LoggingLevel.WARN, 'LLM parsing failed, using rule-based fallback. ' + fallbackReason);
        }
        if (result == null) {
            result = parseWithRules(cvText);
            result.parsedBy = PARSED_BY_RULES;
            result.fallbackReason = fallbackReason;
        }

        result.normalize();
        reconcileYears(result);
        validateAgainstSource(result, cvText);
        computeMissingFields(result);
        return result;
    }

    // ------------------------------------------------------------------ LLM

    private static ParsedCv parseWithLlm(String cvText) {
        String raw = llm.generate(cvText);
        if (String.isBlank(raw)) {
            throw new CvParseException('The model returned an empty response.');
        }
        return (ParsedCv) JSON.deserialize(extractJson(raw), ParsedCv.class);
    }

    /** Models sometimes wrap JSON in ```json fences or add a sentence - keep only the object. */
    @TestVisible
    private static String extractJson(String raw) {
        Integer first = raw.indexOf('{');
        Integer last = raw.lastIndexOf('}');
        if (first < 0 || last <= first) {
            throw new CvParseException('Model response did not contain a JSON object.');
        }
        return raw.substring(first, last + 1);
    }

    // ---------------------------------------------------------- Rule-based

    @TestVisible
    private static ParsedCv parseWithRules(String cvText) {
        ParsedCv cv = new ParsedCv();

        Set<String> emails = findAll(EMAIL_PATTERN, cvText, true);
        if (!emails.isEmpty()) {
            cv.email = new List<String>(emails)[0];
            if (emails.size() > 1) {
                cv.conflicts.add(
                    'Email: the CV lists more than one address (' + String.join(new List<String>(emails), ', ') +
                    '). The first one was saved; please confirm the preferred contact.'
                );
            }
        }

        // Date ranges like "2019 - 2024" also match the pattern; a real phone has 9-15 digits.
        for (String candidate : findAll(PHONE_PATTERN, cvText, false)) {
            Integer digitCount = candidate.replaceAll('\\D', '').length();
            if (digitCount >= 9 && digitCount <= 15) {
                cv.phone = candidate;
                break;
            }
        }

        // First non-empty line is the name in the vast majority of CVs,
        // but only accept it if it looks like a name (2-4 words, no digits/@).
        for (String line : cvText.split('\n')) {
            String trimmed = line.trim();
            if (String.isBlank(trimmed)) {
                continue;
            }
            Integer words = trimmed.split('\\s+').size();
            if (words >= 2 && words <= 4 && !trimmed.containsAny('@0123456789')) {
                cv.name = trimmed;
            }
            break;
        }

        Matcher years = YEARS_PATTERN.matcher(cvText);
        if (years.find()) {
            cv.yearsOfExperience = Integer.valueOf(years.group(1));
            cv.uncertainties.add(
                'Years of experience: taken from the phrase "' + years.group().trim() +
                '" by the rule-based parser and not cross-checked against employment dates.'
            );
        }

        cv.skills = extractSection(cvText, new List<String>{ 'skills', 'technical skills', 'core skills' });
        return cv;
    }

    private static Set<String> findAll(Pattern p, String text, Boolean lowerCase) {
        Set<String> found = new Set<String>();
        Matcher m = p.matcher(text);
        while (m.find()) {
            String value = m.group().trim();
            found.add(lowerCase ? value.toLowerCase() : value);
        }
        return found;
    }

    /** Returns comma/bullet separated items under the first matching heading. */
    private static List<String> extractSection(String text, List<String> headings) {
        List<String> items = new List<String>();
        List<String> lines = text.split('\n');
        for (Integer i = 0; i < lines.size(); i++) {
            String heading = lines[i].trim().toLowerCase().removeEnd(':');
            if (!headings.contains(heading)) {
                continue;
            }
            for (Integer j = i + 1; j < lines.size() && j <= i + 8; j++) {
                String line = lines[j].trim();
                if (String.isBlank(line)) {
                    if (!items.isEmpty()) {
                        break;
                    }
                    continue;
                }
                for (String part : line.split('[,•|·;]')) {
                    String skill = part.replaceFirst('^[-*\\s]+', '').trim();
                    if (skill.length() > 1 && skill.length() < 40) {
                        items.add(skill);
                    }
                }
            }
            break;
        }
        return items;
    }

    // ------------------------------------------------------------ Validation

    /**
     * The model reports what the CV claims and what the dates imply; the comparison
     * is done here so the rule is deterministic and testable.
     * A gap of 2+ years is reported as a conflict (often an outdated CV).
     */
    @TestVisible
    private static void reconcileYears(ParsedCv cv) {
        Integer stated = cv.statedYearsOfExperience;
        Integer computed = cv.computedYearsOfExperience;
        if (stated == null && computed == null) {
            return; // keep whatever the fallback parser found
        }
        if (stated != null) {
            cv.yearsOfExperience = stated;
            if (computed != null && Math.abs(stated - computed) >= 2) {
                cv.conflicts.add(
                    'Years of experience: the CV states ' + stated + ' years, but the listed employment dates add up to about ' +
                    computed + ' years. The CV may be out of date; please confirm with the candidate.'
                );
            }
        } else {
            cv.yearsOfExperience = computed;
            cv.uncertainties.add(
                'Years of experience: not stated in the CV; estimated as ' + computed + ' years from the employment dates.'
            );
        }
    }

    /**
     * Guard against hallucinated contact details: anything the model returned
     * for email/phone must literally exist in the CV text.
     */
    @TestVisible
    private static void validateAgainstSource(ParsedCv cv, String cvText) {
        String haystack = cvText.toLowerCase();
        if (String.isNotBlank(cv.email) && !haystack.contains(cv.email.toLowerCase())) {
            cv.conflicts.add(
                'Email: the extracted value "' + cv.email + '" could not be verified against the CV text and was not saved.'
            );
            cv.email = null;
        }
        if (String.isNotBlank(cv.phone)) {
            String digits = cv.phone.replaceAll('\\D', '');
            String sourceDigits = cvText.replaceAll('\\D', '');
            if (digits.length() < 7 || !sourceDigits.contains(digits)) {
                cv.conflicts.add(
                    'Phone: the extracted value "' + cv.phone + '" could not be verified against the CV text and was not saved.'
                );
                cv.phone = null;
            }
        }
        if (cv.yearsOfExperience != null && (cv.yearsOfExperience < 0 || cv.yearsOfExperience > 60)) {
            cv.conflicts.add(
                'Years of experience: the value ' + cv.yearsOfExperience + ' is outside a realistic range and was not saved.'
            );
            cv.yearsOfExperience = null;
        }
    }

    private static void computeMissingFields(ParsedCv cv) {
        cv.missingFields.clear();
        if (String.isBlank(cv.name)) {
            cv.missingFields.add('Name');
        }
        if (String.isBlank(cv.email)) {
            cv.missingFields.add('Email');
        }
        if (String.isBlank(cv.phone)) {
            cv.missingFields.add('Phone');
        }
        if (String.isBlank(cv.title)) {
            cv.missingFields.add('Title');
        }
        if (cv.yearsOfExperience == null) {
            cv.missingFields.add('Years of Experience');
        }
        if (cv.skills == null || cv.skills.isEmpty()) {
            cv.missingFields.add('Skills');
        }
        if (cv.experience == null || cv.experience.isEmpty()) {
            cv.missingFields.add('Experience');
        }
        if (cv.education == null || cv.education.isEmpty()) {
            cv.missingFields.add('Education');
        }
    }

    public class CvParseException extends Exception {
    }
}
