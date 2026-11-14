/** Tests run as a recruiter with only the CV_Review_Agent_User permission set, proving USER_MODE access works. */
@IsTest
public class TestUserFactory {
    public static User recruiter() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User u = new User(
            Alias = 'recr',
            Email = 'recruiter' + unique + '@example.com',
            Username = 'recruiter' + unique + '@cvreview.test',
            LastName = 'Recruiter',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Africa/Cairo',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'CV_Review_Agent_User'];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    /** The recruiter created in @TestSetup. */
    public static User existingRecruiter() {
        return [SELECT Id FROM User WHERE Username LIKE 'recruiter%@cvreview.test' ORDER BY CreatedDate DESC LIMIT 1];
    }
}
