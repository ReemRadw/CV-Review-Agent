/**
 * Normalised Candidate Card produced from a raw CV.
 * Every field is nullable on purpose: a value that is not stated in the CV
 * stays null and is reported in missingFields instead of being guessed.
 */
public with sharing class ParsedCv {
    public String name;
    public String email;
    public String phone;
    public String title;
    public Integer yearsOfExperience;
    public List<String> skills = new List<String>();
    public List<ExperienceItem> experience = new List<ExperienceItem>();
    public List<EducationItem> education = new List<EducationItem>();
    public List<String> achievements = new List<String>();

    /** Contradictions found inside the CV (e.g. two different emails). */
    public List<String> conflicts = new List<String>();
    /** Filled by the service, never trusted from the model. */
    public List<String> missingFields = new List<String>();
    /** 'Prompt Template' or 'Rule-based fallback' - surfaced to the recruiter. */
    public String parsedBy;

    /** JSON from the model may contain explicit nulls - make collections safe to use. */
    public ParsedCv normalize() {
        skills = skills == null ? new List<String>() : skills;
        experience = experience == null ? new List<ExperienceItem>() : experience;
        education = education == null ? new List<EducationItem>() : education;
        achievements = achievements == null ? new List<String>() : achievements;
        conflicts = conflicts == null ? new List<String>() : conflicts;
        missingFields = new List<String>();
        name = String.isBlank(name) ? null : name.trim();
        email = String.isBlank(email) ? null : email.trim().toLowerCase();
        phone = String.isBlank(phone) ? null : phone.trim();
        title = String.isBlank(title) ? null : title.trim();
        return this;
    }

    public class ExperienceItem {
        public String role;
        public String company;
        public String period;
        public String summary;
    }

    public class EducationItem {
        public String degree;
        public String institution;
        public String year;
    }
}
