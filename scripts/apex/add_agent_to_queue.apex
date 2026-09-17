/**
 * Sets up one agent: creates their agent record if needed, sets capacity and skills,
 * and adds them to a queue.
 *
 * Edit the three values below, then:
 * sf apex run --file scripts/apex/add_agent_to_queue.apex --target-org <org>
 */
final String USERNAME = 'someone@example.com';   // the agent's Salesforce username
final String QUEUE_DEVELOPER_NAME = 'CUSTOMER_SERVICE';
final String SKILLS = 'BILLING';                 // semicolon separated, or null
final Decimal MAX_CAPACITY = 5;
final Decimal SKILL_LEVEL = 3;                   // 1-5, used by Skill Based routing

User u = [SELECT Id, Name FROM User WHERE Username = :USERNAME LIMIT 1];
Service_Queue__c q = [SELECT Id, Name FROM Service_Queue__c WHERE Developer_Name__c = :QUEUE_DEVELOPER_NAME LIMIT 1];

Service_Agent__c agent = AgentPresenceService.ensureAgent(u.Id);
agent.Max_Capacity__c = MAX_CAPACITY;
agent.Skills__c = SKILLS;
agent.Is_Active__c = true;
update agent;

Service_Agent_Queue__c membership = new Service_Agent_Queue__c(
    Agent__c = agent.Id,
    Queue__c = q.Id,
    Active__c = true,
    Priority__c = 1,
    Skill_Level__c = SKILL_LEVEL,
    Membership_Key__c = agent.Id + '-' + q.Id
);
upsert membership Membership_Key__c;

System.debug(u.Name + ' is now a member of ' + q.Name + ' with capacity ' + MAX_CAPACITY);
System.debug('They will start receiving work once they set a presence status that accepts work.');
