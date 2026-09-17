@isTest
private class RoutingSchedulerTest {

    @isTest
    static void workNearingItsSlaIsEscalatedOnce() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        // 100 minutes into a 100 minute SLA: well past the 80% threshold.
        item.Requested_At__c = System.now().addMinutes(-100);
        item.Due_At__c = System.now();
        item.Priority__c = 5;
        RoutingEngine.suppressTriggerRouting = true;
        update item;
        RoutingEngine.suppressTriggerRouting = false;

        Test.startTest();
        Integer escalated = RoutingScheduler.escalateApproachingSla();
        Integer escalatedAgain = RoutingScheduler.escalateApproachingSla();
        Test.stopTest();

        System.assertEquals(1, escalated);
        System.assertEquals(0, escalatedAgain, 'Escalation happens once, not on every pass');

        Service_Work_Item__c after = [
            SELECT Priority__c, Escalated__c FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals(3, after.Priority__c.intValue(), 'Priority should improve by two steps');
        System.assert(after.Escalated__c);
    }

    @isTest
    static void freshWorkIsNotEscalated() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        item.Requested_At__c = System.now();
        item.Due_At__c = System.now().addHours(8);
        RoutingEngine.suppressTriggerRouting = true;
        update item;
        RoutingEngine.suppressTriggerRouting = false;

        Test.startTest();
        System.assertEquals(0, RoutingScheduler.escalateApproachingSla());
        Test.stopTest();
    }

    @isTest
    static void longWaitsMoveToTheOverflowQueue() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c overflow = ServiceRoutingTestFactory.queue('TIER_2_SUPPORT', 'Least Active');
        Service_Queue__c main = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        main.Overflow_Queue__c = overflow.Id;
        main.Overflow_After_Minutes__c = 30;
        update main;

        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(main);
        item.Requested_At__c = System.now().addMinutes(-45);
        RoutingEngine.suppressTriggerRouting = true;
        update item;
        RoutingEngine.suppressTriggerRouting = false;

        Test.startTest();
        Integer moved = RoutingScheduler.overflowLongWaits();
        Test.stopTest();

        System.assertEquals(1, moved);
        System.assertEquals(overflow.Id,
            [SELECT Queue__c FROM Service_Work_Item__c WHERE Id = :item.Id].Queue__c);
    }

    @isTest
    static void recentWorkDoesNotOverflow() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c overflow = ServiceRoutingTestFactory.queue('TIER_2_SUPPORT', 'Least Active');
        Service_Queue__c main = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        main.Overflow_Queue__c = overflow.Id;
        main.Overflow_After_Minutes__c = 30;
        update main;
        ServiceRoutingTestFactory.workItem(main);

        Test.startTest();
        System.assertEquals(0, RoutingScheduler.overflowLongWaits(), 'Nothing has waited long enough yet');
        Test.stopTest();
    }

    @isTest
    static void theHeartbeatRunsEndToEnd() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c a = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.membership(a, q, 3);
        ServiceRoutingTestFactory.workItems(q, 2, 5, 1);

        Test.startTest();
        System.schedule('Routing heartbeat test', '0 0 1 * * ?', new RoutingScheduler());
        RoutingScheduler.run();
        Test.stopTest();

        System.assertEquals(2, [
            SELECT COUNT() FROM Service_Work_Item__c WHERE Assigned_Agent__c = :a.Id
        ], 'The heartbeat should have picked up the queued work');
    }

    @isTest
    static void loggingRespectsTheConfiguredLevel() {
        RoutingSettings.override(new Service_Routing_Setting__mdt(
            DeveloperName = 'Default', Enable_Routing__c = true, Log_Level__c = 'None',
            Max_Decline_Count__c = 3, Decline_Cooldown_Minutes__c = 10,
            Push_Timeout_Seconds__c = 30, Routing_Batch_Size__c = 200));

        RoutingLogger.log(null, 'Created', null, null, 'should be dropped');
        System.assertEquals(0, RoutingLogger.pending().size(), 'Log Level None writes nothing');

        ServiceRoutingTestFactory.stubSettings();
        RoutingLogger.log(null, 'Created', null, null, 'should be buffered');
        System.assertEquals(1, RoutingLogger.pending().size());

        RoutingLogger.verbose(null, 'Routed', null, null, 'verbose only');
        System.assertEquals(1, RoutingLogger.pending().size(),
            'Verbose entries are dropped at Standard level');

        Test.startTest();
        RoutingLogger.flush();
        Test.stopTest();
        System.assertEquals(0, RoutingLogger.pending().size(), 'Flushing empties the buffer');
    }
}
