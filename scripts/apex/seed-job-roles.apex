// Sample job roles for testing the agent.
// Run: sf apex run --file scripts/apex/seed-job-roles.apex --target-org <alias>
List<Job_Role__c> roles = new List<Job_Role__c>{
    new Job_Role__c(
        Name = 'Senior Salesforce Developer',
        Min_Years__c = 5,
        Required_Skills__c = 'Apex, LWC, SOQL, Flows, REST API, Git',
        Description__c = 'Builds and owns custom Sales/Service Cloud solutions, integrations and code quality for a delivery team.'
    ),
    new Job_Role__c(
        Name = 'Salesforce Administrator',
        Min_Years__c = 2,
        Required_Skills__c = 'Flows, Reports, Dashboards, Validation Rules, Permission Sets',
        Description__c = 'Maintains the org configuration, automation, security model and reporting for business users.'
    ),
    new Job_Role__c(
        Name = 'Agentforce Developer',
        Min_Years__c = 3,
        Required_Skills__c = 'Apex, Agentforce, Prompt Builder, LWC',
        Description__c = 'Designs Agentforce agents, custom Apex actions and prompt templates.'
    )
};
insert roles;
System.debug('Inserted ' + roles.size() + ' job roles');
