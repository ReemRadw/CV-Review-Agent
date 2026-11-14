/**
 * Shared logic behind the agent's invocable actions:
 * record resolution, candidate search, evidence lookup and role-fit scoring.
 *
 * Scoring is deliberately deterministic (no LLM): the same inputs always give
 * the same score, and every point can be traced back to a rule. The agent's
 * job is to explain these results, not to invent them.
 */
public with sharing class CandidateAgentService {
    public static final Integer STRONG_MATCH_THRESHOLD = 70;
    private static final Integer SKILL_WEIGHT = 60;
    private static final Integer EXPERIENCE_WEIGHT = 25;
    private static final Integer QUALITY_WEIGHT = 15;
    private static final Integer MAX_SEARCH_ROWS = 500;

    /** Different spellings of the same skill. Ambiguous abbreviations such as "SF" are intentionally excluded. */
    private static final Map<String, List<String>> SKILL_ALIASES = new Map<String, List<String>>{
        'lwc' => new List<String>{ 'lightning web components', 'lightning web component' },
        'lightning web components' => new List<String>{ 'lwc' },
        'soql' => new List<String>{ 'soql/sosl' },
        'flows' => new List<String>{ 'flow', 'flow builder' },
        'flow' => new List<String>{ 'flows', 'flow builder' },
        'rest' => new List<String>{ 'rest api', 'rest apis', 'rest/soap' },
        'rest api' => new List<String>{ 'rest', 'rest apis', 'rest/soap' },
        'agentforce' => new List<String>{ 'agentforce agents', 'agentforce specialist' },
        'ci/cd' => new List<String>{ 'github actions', 'jenkins' }
    };

    public class AgentException extends Exception {
    }

    // ------------------------------------------------------------ resolution

    private static final String CANDIDATE_FIELDS =
        'Id, Name, Email__c, Phone__c, Title__c, Years_of_Experience__c, Skills__c, Experience__c, ' +
        'Education__c, Achievements__c, Missing_Info__c, Uncertain_Info__c, Conflicts__c, Data_Status__c, CV_Text__c';

    public static Candidate__c resolveCandidate(String reference) {
        List<Candidate__c> found = findCandidates(reference);
        if (found.isEmpty()) {
            throw new AgentException('No candidate matches "' + reference + '".');
        }
        if (found.size() > 1) {
            throw new AgentException(
                'More than one candidate matches "' + reference + '": ' + joinNames(found) + '. Please specify which one.'
            );
        }
        return found[0];
    }

    public static List<Candidate__c> findCandidates(String reference) {
        if (String.isBlank(reference)) {
            throw new AgentException('A candidate name or Id is required.');
        }
        String ref = reference.trim();
        if (isIdOf(ref, Candidate__c.SObjectType)) {
            return Database.queryWithBinds(
                'SELECT ' + CANDIDATE_FIELDS + ' FROM Candidate__c WHERE Id = :ref',
                new Map<String, Object>{ 'ref' => ref },
                AccessLevel.USER_MODE
            );
        }
        List<Candidate__c> exact = Database.queryWithBinds(
            'SELECT ' + CANDIDATE_FIELDS + ' FROM Candidate__c WHERE Name = :ref LIMIT 2',
            new Map<String, Object>{ 'ref' => ref },
            AccessLevel.USER_MODE
        );
        if (!exact.isEmpty()) {
            return exact;
        }
        String pattern = '%' + ref + '%';
        return Database.queryWithBinds(
            'SELECT ' + CANDIDATE_FIELDS + ' FROM Candidate__c WHERE Name LIKE :pattern LIMIT 5',
            new Map<String, Object>{ 'pattern' => pattern },
            AccessLevel.USER_MODE
        );
    }

    public static Job_Role__c resolveJobRole(String reference) {
        if (String.isBlank(reference)) {
            throw new AgentException('A job role name or Id is required.');
        }
        String ref = reference.trim();
        List<Job_Role__c> roles;
        if (isIdOf(ref, Job_Role__c.SObjectType)) {
            roles = [SELECT Id, Name, Description__c, Required_Skills__c, Min_Years__c FROM Job_Role__c WHERE Id = :ref WITH USER_MODE];
        } else {
            roles = [SELECT Id, Name, Description__c, Required_Skills__c, Min_Years__c FROM Job_Role__c WHERE Name = :ref WITH USER_MODE LIMIT 2];
            if (roles.isEmpty()) {
                String pattern = '%' + ref + '%';
                roles = [SELECT Id, Name, Description__c, Required_Skills__c, Min_Years__c FROM Job_Role__c WHERE Name LIKE :pattern WITH USER_MODE LIMIT 5];
            }
        }
        if (roles.isEmpty()) {
            List<String> available = new List<String>();
            for (Job_Role__c r : [SELECT Name FROM Job_Role__c WITH USER_MODE ORDER BY Name LIMIT 20]) {
                available.add(r.Name);
            }
            throw new AgentException(
                'No job role matches "' + reference + '". Available roles: ' +
                (available.isEmpty() ? 'none defined yet' : String.join(available, ', ')) + '.'
            );
        }
        if (roles.size() > 1) {
            List<String> names = new List<String>();
            for (Job_Role__c r : roles) {
                names.add(r.Name);
            }
            throw new AgentException('More than one job role matches "' + reference + '": ' + String.join(names, ', ') + '.');
        }
        return roles[0];
    }

    // ---------------------------------------------------------------- search

    /**
     * Long text fields cannot be filtered in SOQL, so keyword matching happens in Apex.
     * Fine for the expected volume (hundreds of CVs); see README for the scaling note.
     */
    public static List<Candidate__c> search(List<String> keywords, Integer minYears, String status) {
        List<Candidate__c> rows = Database.query(
            'SELECT ' + CANDIDATE_FIELDS + ' FROM Candidate__c WITH USER_MODE ORDER BY LastModifiedDate DESC LIMIT ' + MAX_SEARCH_ROWS
        );
        List<Candidate__c> result = new List<Candidate__c>();
        for (Candidate__c c : rows) {
            if (minYears != null && (c.Years_of_Experience__c == null || c.Years_of_Experience__c < minYears)) {
                continue;
            }
            if (String.isNotBlank(status) && c.Data_Status__c != status) {
                continue;
            }
            String corpus = searchableText(c);
            Boolean matchesAll = true;
            for (String keyword : keywords) {
                if (!containsTerm(corpus, keyword)) {
                    matchesAll = false;
                    break;
                }
            }
            if (matchesAll) {
                result.add(c);
            }
        }
        return result;
    }

    // -------------------------------------------------------------- evidence

    public class Evidence {
        public Integer line;
        public String text;
    }

    /** Returns the CV lines that mention any of the terms, with line numbers for citation. */
    public static List<Evidence> findEvidence(Candidate__c candidate, List<String> terms, Integer maxLines) {
        List<Evidence> hits = new List<Evidence>();
        if (String.isBlank(candidate.CV_Text__c) || terms.isEmpty()) {
            return hits;
        }
        List<String> lines = candidate.CV_Text__c.split('\n');
        for (Integer i = 0; i < lines.size() && hits.size() < maxLines; i++) {
            String line = lines[i].trim();
            if (String.isBlank(line)) {
                continue;
            }
            for (String term : terms) {
                if (containsTerm(line.toLowerCase(), term)) {
                    Evidence e = new Evidence();
                    e.line = i + 1;
                    e.text = line.abbreviate(300);
                    hits.add(e);
                    break;
                }
            }
        }
        return hits;
    }

    // --------------------------------------------------------------- scoring

    public class ScoreResult {
        public Id candidateId;
        public String candidateName;
        public Integer score;
        public Boolean strongMatch;
        public Integer skillPoints;
        public Integer experiencePoints;
        public Integer dataQualityPoints;
        public List<String> matchedSkills = new List<String>();
        public List<String> missingSkills = new List<String>();
        public List<String> strengths = new List<String>();
        public List<String> concerns = new List<String>();
        public String explanation;
        /** Why this candidate is ranked above the next one (scoring explainability). */
        public String rankedAboveNextBecause;
    }

    public static List<ScoreResult> scoreAndRank(Job_Role__c role, List<Candidate__c> candidates) {
        List<ScoreResult> results = new List<ScoreResult>();
        for (Candidate__c c : candidates) {
            results.add(score(role, c));
        }
        // Simple insertion sort by score desc, then name - keeps ordering deterministic.
        for (Integer i = 1; i < results.size(); i++) {
            ScoreResult current = results[i];
            Integer j = i - 1;
            while (j >= 0 && isRankedBelow(results[j], current)) {
                results[j + 1] = results[j];
                j--;
            }
            results[j + 1] = current;
        }
        for (Integer i = 0; i < results.size() - 1; i++) {
            results[i].rankedAboveNextBecause = compare(results[i], results[i + 1]);
        }
        return results;
    }

    /** Explains the gap between two adjacent candidates, component by component. */
    @TestVisible
    private static String compare(ScoreResult higher, ScoreResult lower) {
        List<String> reasons = new List<String>();
        addDifference(reasons, 'skills', higher.skillPoints - lower.skillPoints);
        addDifference(reasons, 'experience', higher.experiencePoints - lower.experiencePoints);
        addDifference(reasons, 'data quality', higher.dataQualityPoints - lower.dataQualityPoints);
        Integer gap = higher.score - lower.score;
        if (gap == 0) {
            return 'Tied with ' + lower.candidateName + ' at ' + higher.score + '/100; ordered alphabetically.';
        }
        return 'Ranked ' + gap + ' points above ' + lower.candidateName + ' (' + String.join(reasons, ', ') + ').';
    }

    private static void addDifference(List<String> reasons, String component, Integer diff) {
        if (diff != 0) {
            reasons.add(component + ' ' + (diff > 0 ? '+' : '') + diff);
        }
    }

    private static Boolean isRankedBelow(ScoreResult a, ScoreResult b) {
        return a.score < b.score || (a.score == b.score && a.candidateName > b.candidateName);
    }

    public static ScoreResult score(Job_Role__c role, Candidate__c c) {
        ScoreResult r = new ScoreResult();
        r.candidateId = c.Id;
        r.candidateName = c.Name;

        // 1. Skills (60)
        List<String> required = splitList(role.Required_Skills__c);
        String corpus = ((c.Skills__c == null ? '' : c.Skills__c) + '\n' +
            (c.Title__c == null ? '' : c.Title__c) + '\n' +
            (c.Experience__c == null ? '' : c.Experience__c)).toLowerCase();
        for (String skill : required) {
            if (matchesSkill(corpus, skill)) {
                r.matchedSkills.add(skill);
            } else {
                r.missingSkills.add(skill);
            }
        }
        if (required.isEmpty()) {
            r.skillPoints = SKILL_WEIGHT;
            r.concerns.add('The role has no required skills defined, so skills were not assessed.');
        } else {
            r.skillPoints = Math.round(SKILL_WEIGHT * r.matchedSkills.size() / (Decimal) required.size());
            if (!r.matchedSkills.isEmpty()) {
                r.strengths.add('Covers ' + r.matchedSkills.size() + ' of ' + required.size() + ' required skills: ' + String.join(r.matchedSkills, ', ') + '.');
            }
            if (!r.missingSkills.isEmpty()) {
                r.concerns.add('No evidence in the CV for: ' + String.join(r.missingSkills, ', ') + '.');
            }
        }

        // 2. Experience (25)
        Decimal years = c.Years_of_Experience__c;
        Decimal minYears = role.Min_Years__c;
        if (minYears == null || minYears <= 0) {
            r.experiencePoints = EXPERIENCE_WEIGHT;
        } else if (years == null) {
            r.experiencePoints = 0;
            r.concerns.add('Years of experience are not stated in the CV (role requires ' + minYears + '+).');
        } else if (years >= minYears) {
            r.experiencePoints = EXPERIENCE_WEIGHT;
            r.strengths.add(years + ' years of experience meets the ' + minYears + '+ requirement.');
        } else {
            r.experiencePoints = Math.round(EXPERIENCE_WEIGHT * years / minYears);
            r.concerns.add(years + ' years of experience is below the ' + minYears + '+ requirement.');
        }

        // 3. Data quality (15) - a less reliable profile should rank lower, not disappear.
        if (c.Data_Status__c == CvIngestionController.STATUS_COMPLETE) {
            r.dataQualityPoints = QUALITY_WEIGHT;
        } else if (c.Data_Status__c == CvIngestionController.STATUS_PARTIAL) {
            r.dataQualityPoints = 8;
            r.concerns.add('Profile is partial' + (String.isBlank(c.Missing_Info__c) ? '' : ' (missing: ' + c.Missing_Info__c + ')') + '.');
        } else {
            r.dataQualityPoints = 3;
            r.concerns.add('The CV contains conflicting information that should be clarified.');
        }
        if (String.isNotBlank(c.Uncertain_Info__c)) {
            r.concerns.add('Some details are uncertain - see Uncertain Info on the candidate record.');
        }

        r.score = r.skillPoints + r.experiencePoints + r.dataQualityPoints;
        r.strongMatch = r.score >= STRONG_MATCH_THRESHOLD;
        r.explanation =
            'Score ' + r.score + '/100 = skills ' + r.skillPoints + '/' + SKILL_WEIGHT +
            ' + experience ' + r.experiencePoints + '/' + EXPERIENCE_WEIGHT +
            ' + data quality ' + r.dataQualityPoints + '/' + QUALITY_WEIGHT + '.';
        return r;
    }

    // --------------------------------------------------------------- helpers

    public static List<String> splitList(String value) {
        List<String> items = new List<String>();
        if (String.isBlank(value)) {
            return items;
        }
        for (String part : value.split('[,;\\n]')) {
            String item = part.trim();
            if (String.isNotBlank(item)) {
                items.add(item);
            }
        }
        return items;
    }

    private static Boolean matchesSkill(String corpus, String skill) {
        String key = skill.toLowerCase().trim();
        if (containsTerm(corpus, key)) {
            return true;
        }
        if (SKILL_ALIASES.containsKey(key)) {
            for (String alias : SKILL_ALIASES.get(key)) {
                if (containsTerm(corpus, alias)) {
                    return true;
                }
            }
        }
        return false;
    }

    /** Whole-word, case-insensitive match so "Java" does not match "JavaScript". */
    public static Boolean containsTerm(String text, String term) {
        if (String.isBlank(text) || String.isBlank(term)) {
            return false;
        }
        String haystack = text.toLowerCase();
        String needle = term.toLowerCase().trim();
        Integer idx = haystack.indexOf(needle);
        while (idx >= 0) {
            Boolean startOk = idx == 0 || !haystack.substring(idx - 1, idx).isAlphanumeric();
            Integer endIdx = idx + needle.length();
            Boolean endOk = endIdx >= haystack.length() || !haystack.substring(endIdx, endIdx + 1).isAlphanumeric();
            if (startOk && endOk) {
                return true;
            }
            idx = haystack.indexOf(needle, idx + 1);
        }
        return false;
    }

    private static String searchableText(Candidate__c c) {
        List<String> parts = new List<String>();
        for (String value : new List<String>{
            c.Name, c.Title__c, c.Skills__c, c.Experience__c, c.Education__c, c.Achievements__c, c.CV_Text__c
        }) {
            if (value != null) {
                parts.add(value);
            }
        }
        return String.join(parts, '\n').toLowerCase();
    }

    private static Boolean isIdOf(String value, SObjectType type) {
        if (!Pattern.matches('[a-zA-Z0-9]{15}|[a-zA-Z0-9]{18}', value)) {
            return false;
        }
        try {
            return ((Id) value).getSObjectType() == type;
        } catch (Exception e) {
            return false;
        }
    }

    public static String joinNames(List<Candidate__c> candidates) {
        List<String> names = new List<String>();
        for (Candidate__c c : candidates) {
            names.add(c.Name);
        }
        return String.join(names, ', ');
    }
}
