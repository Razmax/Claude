@isTest
private class RoutingEngineTest {

    @isTest
    static void leastActiveSendsWorkToTheQuietestAgent() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(2);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c busy = ServiceRoutingTestFactory.agent(users[0], 5, null);
        Service_Agent__c quiet = ServiceRoutingTestFactory.agent(users[1], 5, null);
        ServiceRoutingTestFactory.membership(busy, q, 3);
        ServiceRoutingTestFactory.membership(quiet, q, 3);

        busy.Active_Work_Count__c = 3;
        busy.Current_Load__c = 3;
        update busy;

        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        Test.startTest();
        RoutingEngine.Result result = RoutingEngine.route(new Set<Id>{item.Id});
        Test.stopTest();

        System.assertEquals(1, result.assigned, 'The item should have been assigned');
        Service_Work_Item__c routed = [
            SELECT Assigned_Agent__c, Status__c, Push_Expires_At__c, Assigned_User__c
            FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals(quiet.Id, routed.Assigned_Agent__c, 'Least busy agent should win');
        System.assertEquals('Assigned', routed.Status__c);
        System.assertEquals(users[1].Id, routed.Assigned_User__c, 'Assigned user should mirror the agent');
        System.assertNotEquals(null, routed.Push_Expires_At__c, 'A push timeout should be set');
    }

    @isTest
    static void capacityStopsOverAssignment() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c only = ServiceRoutingTestFactory.agent(users[0], 2, null);
        ServiceRoutingTestFactory.membership(only, q, 3);

        // Three items, capacity for two.
        List<Service_Work_Item__c> items = ServiceRoutingTestFactory.workItems(q, 3, 5, 1);

        Test.startTest();
        RoutingEngine.Result result = RoutingEngine.routeAllPending();
        Test.stopTest();

        System.assertEquals(2, result.assigned, 'Only two items fit in the agent capacity');
        System.assertEquals(1, result.unassigned, 'The third item should stay queued');

        Service_Agent__c after = [SELECT Current_Load__c, Active_Work_Count__c FROM Service_Agent__c WHERE Id = :only.Id];
        System.assertEquals(2, after.Current_Load__c.intValue(), 'Load should equal the assigned weight');
        System.assertEquals(2, after.Active_Work_Count__c.intValue());

        Integer stillWaiting = [
            SELECT COUNT() FROM Service_Work_Item__c
            WHERE Id IN :items AND Assigned_Agent__c = NULL AND Status__c = 'Pending'
        ];
        System.assertEquals(1, stillWaiting);
    }

    @isTest
    static void capacityWeightIsRespected() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CREDIT_REVIEW', 'Most Available');
        Service_Agent__c reviewer = ServiceRoutingTestFactory.agent(users[0], 3, 'CREDIT');
        ServiceRoutingTestFactory.membership(reviewer, q, 5);

        // Weight 2 each: only one fits in a capacity of 3.
        ServiceRoutingTestFactory.workItems(q, 2, 5, 2);

        Test.startTest();
        RoutingEngine.Result result = RoutingEngine.routeAllPending();
        Test.stopTest();

        System.assertEquals(1, result.assigned, 'A second weight-2 item would exceed capacity 3');
        Service_Agent__c after = [SELECT Current_Load__c FROM Service_Agent__c WHERE Id = :reviewer.Id];
        System.assertEquals(2, after.Current_Load__c.intValue());
    }

    @isTest
    static void requiredSkillsFilterOutUnqualifiedAgents() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(2);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CREDIT_REVIEW', 'Skill Based');
        Service_Agent__c generalist = ServiceRoutingTestFactory.agent(users[0], 5, 'BILLING');
        Service_Agent__c specialist = ServiceRoutingTestFactory.agent(users[1], 5, 'BILLING;CREDIT');
        ServiceRoutingTestFactory.membership(generalist, q, 5);
        ServiceRoutingTestFactory.membership(specialist, q, 1);

        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        item.Required_Skills__c = 'CREDIT';
        update item;

        Test.startTest();
        RoutingEngine.route(new Set<Id>{item.Id});
        Test.stopTest();

        Service_Work_Item__c routed = [SELECT Assigned_Agent__c FROM Service_Work_Item__c WHERE Id = :item.Id];
        System.assertEquals(specialist.Id, routed.Assigned_Agent__c,
            'Only the agent holding the CREDIT skill is eligible, even with a lower skill level');
    }

    @isTest
    static void presenceChannelRestrictionIsHonoured() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c phoneOnly = ServiceRoutingTestFactory.agent(users[0], 5, null);
        phoneOnly.Presence_Status__c = ServiceRoutingTestFactory.PHONE_ONLY;
        update phoneOnly;
        ServiceRoutingTestFactory.membership(phoneOnly, q, 3);

        // The work item is on the Case channel; this agent only takes Phone and Callback.
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        Test.startTest();
        RoutingEngine.Result result = RoutingEngine.route(new Set<Id>{item.Id});
        Test.stopTest();

        System.assertEquals(0, result.assigned, 'A phone-only agent should not receive Case work');
        System.assertEquals(1, result.unassigned);
    }

    @isTest
    static void offlineAgentsAreNeverConsidered() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c away = ServiceRoutingTestFactory.agent(users[0], 5, null);
        away.Accepts_Work__c = false;
        away.Presence_Status__c = ServiceRoutingTestFactory.OFFLINE;
        update away;
        ServiceRoutingTestFactory.membership(away, q, 3);

        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        Test.startTest();
        RoutingEngine.Result result = RoutingEngine.route(new Set<Id>{item.Id});
        Test.stopTest();

        System.assertEquals(0, result.assigned);
    }

    @isTest
    static void roundRobinRotatesByLastAssignment() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(2);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CALLBACKS', 'Round Robin');
        Service_Agent__c recent = ServiceRoutingTestFactory.agent(users[0], 5, null);
        Service_Agent__c stale = ServiceRoutingTestFactory.agent(users[1], 5, null);
        ServiceRoutingTestFactory.membership(recent, q, 3);
        ServiceRoutingTestFactory.membership(stale, q, 3);

        recent.Last_Assigned_At__c = System.now().addMinutes(-1);
        stale.Last_Assigned_At__c = System.now().addHours(-3);
        update new List<Service_Agent__c>{recent, stale};

        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        Test.startTest();
        RoutingEngine.route(new Set<Id>{item.Id});
        Test.stopTest();

        Service_Work_Item__c routed = [SELECT Assigned_Agent__c FROM Service_Work_Item__c WHERE Id = :item.Id];
        System.assertEquals(stale.Id, routed.Assigned_Agent__c, 'The agent idle longest takes the next item');
    }

    @isTest
    static void inactiveQueueStopsRouting() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c a = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.membership(a, q, 3);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        q.Active__c = false;
        update q;

        Test.startTest();
        RoutingEngine.Result result = RoutingEngine.route(new Set<Id>{item.Id});
        Test.stopTest();

        System.assertEquals(0, result.assigned);
        System.assert(!result.messages.isEmpty(), 'The caller should be told why nothing routed');
    }

    @isTest
    static void masterSwitchDisablesRouting() {
        ServiceRoutingTestFactory.stubPresenceStatuses();
        RoutingSettings.override(new Service_Routing_Setting__mdt(
            DeveloperName = 'Default', Enable_Routing__c = false, Routing_Batch_Size__c = 200,
            Max_Decline_Count__c = 3, Decline_Cooldown_Minutes__c = 10, Push_Timeout_Seconds__c = 30,
            Log_Level__c = 'Standard'));

        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c a = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.membership(a, q, 3);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        Test.startTest();
        RoutingEngine.Result result = RoutingEngine.route(new Set<Id>{item.Id});
        Test.stopTest();

        System.assertEquals(0, result.assigned, 'Nothing routes while the master switch is off');
    }

    @isTest
    static void strategyFactoryFallsBackWhenClassIsBad() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = new Service_Queue__c(
            Name = 'Bad', Developer_Name__c = 'BAD', Active__c = true,
            Routing_Strategy_Class__c = 'ThisClassDoesNotExist');
        IRoutingStrategy strategy = RoutingStrategyFactory.forQueue(q);
        System.assert(strategy instanceof LeastActiveRoutingStrategy,
            'An unresolvable class name should fall back rather than break routing');
    }

    @isTest
    static void skillMatchingHandlesBlanksAndCasing() {
        Service_Agent__c a = new Service_Agent__c(Skills__c = 'credit; spanish');
        System.assert(RoutingEngine.hasRequiredSkills(a, null), 'No requirement means anyone qualifies');
        System.assert(RoutingEngine.hasRequiredSkills(a, 'CREDIT'), 'Matching should ignore case and spacing');
        System.assert(RoutingEngine.hasRequiredSkills(a, 'CREDIT;SPANISH'), 'All listed skills must match');
        System.assert(!RoutingEngine.hasRequiredSkills(a, 'CREDIT;FRENCH'), 'A missing skill disqualifies');
        System.assert(!RoutingEngine.hasRequiredSkills(new Service_Agent__c(), 'CREDIT'),
            'An agent with no skills cannot take skilled work');
    }
}
