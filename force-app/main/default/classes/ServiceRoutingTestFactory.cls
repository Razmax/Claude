/**
 * Shared setup for the routing tests.
 *
 * Custom metadata cannot be inserted in a test, so the settings, presence statuses and
 * routing rules are stubbed in memory. That also keeps the tests independent of whatever
 * an admin has since changed in the org.
 */
@isTest
public class ServiceRoutingTestFactory {

    public static final String AVAILABLE = 'Available';
    public static final String OFFLINE = 'Offline';
    public static final String PHONE_ONLY = 'Available_Phone_Only';

    // ------------------------------------------------------------------ config stubs

    public static void stubSettings() {
        stubSettings(3, 30);
    }

    public static void stubSettings(Integer maxDeclines, Integer pushTimeoutSeconds) {
        RoutingSettings.override(new Service_Routing_Setting__mdt(
            DeveloperName = 'Default',
            Enable_Routing__c = true,
            Default_Strategy_Class__c = 'LeastActiveRoutingStrategy',
            Push_Timeout_Seconds__c = pushTimeoutSeconds,
            Max_Decline_Count__c = maxDeclines,
            Decline_Cooldown_Minutes__c = 10,
            Enable_Auto_Accept__c = false,
            Requeue_On_Offline__c = true,
            Escalate_At_Percent_Of_SLA__c = 80,
            Routing_Batch_Size__c = 200,
            Log_Level__c = 'Standard'
        ));
    }

    public static void stubPresenceStatuses() {
        Map<String, Service_Presence_Status__mdt> statuses = new Map<String, Service_Presence_Status__mdt>();
        statuses.put(AVAILABLE, new Service_Presence_Status__mdt(
            DeveloperName = AVAILABLE, MasterLabel = 'Available', Active__c = true,
            Status_Category__c = 'Available', Accepts_Work__c = true, Sort_Order__c = 10,
            Color__c = '#2e844a', Requires_Reason__c = false));
        statuses.put(PHONE_ONLY, new Service_Presence_Status__mdt(
            DeveloperName = PHONE_ONLY, MasterLabel = 'Available - Phone Only', Active__c = true,
            Status_Category__c = 'Available', Accepts_Work__c = true, Channels__c = 'Phone;Callback',
            Sort_Order__c = 20, Color__c = '#0176d3', Requires_Reason__c = false));
        statuses.put('Coaching', new Service_Presence_Status__mdt(
            DeveloperName = 'Coaching', MasterLabel = 'Coaching', Active__c = true,
            Status_Category__c = 'Busy', Accepts_Work__c = false, Sort_Order__c = 30,
            Color__c = '#a6690d', Requires_Reason__c = true));
        statuses.put(OFFLINE, new Service_Presence_Status__mdt(
            DeveloperName = OFFLINE, MasterLabel = 'Offline', Active__c = true,
            Status_Category__c = 'Offline', Accepts_Work__c = false, Sort_Order__c = 40,
            Color__c = '#514f4d', Requires_Reason__c = false));
        PresenceStatusService.overrideStatuses(statuses);
    }

    public static void stubRules(List<Service_Routing_Rule__mdt> rules) {
        RoutingRuleEngine.overrideRules(rules);
    }

    public static void stubDefaultCaseRule(String targetQueueDeveloperName) {
        stubRules(new List<Service_Routing_Rule__mdt>{
            new Service_Routing_Rule__mdt(
                DeveloperName = 'Case_Default', MasterLabel = 'Case Default', Active__c = true,
                Order__c = 90, Source_Object__c = 'Case', Target_Queue__c = targetQueueDeveloperName,
                Priority__c = 5, Capacity_Weight__c = 1, SLA_Minutes__c = 480, Stop_Processing__c = true)
        });
    }

    public static void stubAll() {
        stubSettings();
        stubPresenceStatuses();
        stubRules(new List<Service_Routing_Rule__mdt>());
    }

    // ------------------------------------------------------------------ records

    /** Users must be inserted in their own DML context to avoid MIXED_DML_OPERATION. */
    public static List<User> createUsers(Integer count) {
        Profile standard = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
        String suffix = String.valueOf(Datetime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        List<User> users = new List<User>();
        for (Integer i = 0; i < count; i++) {
            users.add(new User(
                FirstName = 'Routing',
                LastName = 'Agent' + i,
                Alias = 'rtag' + i,
                Email = 'routing.agent' + i + '@example.invalid',
                Username = 'routing.agent' + i + '.' + suffix + '@example.invalid',
                ProfileId = standard.Id,
                TimeZoneSidKey = 'America/New_York',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            ));
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users;
        }
        return users;
    }

    public static Service_Queue__c queue(String developerName, String routingModel) {
        Service_Queue__c q = new Service_Queue__c(
            Name = developerName.replace('_', ' '),
            Developer_Name__c = developerName,
            Active__c = true,
            Priority__c = 5,
            Routing_Model__c = routingModel,
            Default_Capacity_Weight__c = 1,
            Push_Timeout_Seconds__c = 30,
            Allow_Manual_Pull__c = true,
            Allow_Decline__c = true,
            Auto_Accept__c = false
        );
        insert q;
        return q;
    }

    public static Service_Agent__c agent(User u, Decimal capacity, String skills) {
        Service_Agent__c a = new Service_Agent__c(
            Name = u.LastName,
            User__c = u.Id,
            User_Id_Key__c = String.valueOf(u.Id).substring(0, 15),
            Is_Active__c = true,
            Presence_Status__c = AVAILABLE,
            Presence_Status_Label__c = 'Available',
            Presence_Since__c = System.now(),
            Accepts_Work__c = true,
            Max_Capacity__c = capacity,
            Current_Load__c = 0,
            Active_Work_Count__c = 0,
            Skills__c = skills
        );
        insert a;
        return a;
    }

    public static Service_Agent_Queue__c membership(Service_Agent__c a, Service_Queue__c q, Decimal skillLevel) {
        Service_Agent_Queue__c m = new Service_Agent_Queue__c(
            Agent__c = a.Id,
            Queue__c = q.Id,
            Active__c = true,
            Priority__c = 1,
            Skill_Level__c = skillLevel,
            Membership_Key__c = a.Id + '-' + q.Id
        );
        insert m;
        return m;
    }

    /**
     * Inserts work items with trigger routing suppressed so a test controls exactly when
     * the engine runs.
     */
    public static List<Service_Work_Item__c> workItems(Service_Queue__c q, Integer count,
                                                       Decimal priority, Decimal weight) {
        List<Service_Work_Item__c> items = new List<Service_Work_Item__c>();
        for (Integer i = 0; i < count; i++) {
            items.add(new Service_Work_Item__c(
                Queue__c = q.Id,
                Status__c = 'Pending',
                Channel__c = 'Case',
                Subject__c = 'Test work ' + i,
                Priority__c = priority,
                Capacity_Weight__c = weight,
                Requested_At__c = System.now().addMinutes(-i),
                Decline_Count__c = 0,
                Routing_Attempts__c = 0
            ));
        }
        Boolean previous = RoutingEngine.suppressTriggerRouting;
        RoutingEngine.suppressTriggerRouting = true;
        try {
            insert items;
        } finally {
            RoutingEngine.suppressTriggerRouting = previous;
        }
        return items;
    }

    public static Service_Work_Item__c workItem(Service_Queue__c q) {
        return workItems(q, 1, 5, 1)[0];
    }
}
