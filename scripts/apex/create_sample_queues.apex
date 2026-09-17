/**
 * Creates the three queues the sample routing rules reference.
 * Run with: sf apex run --file scripts/apex/create_sample_queues.apex --target-org <org>
 *
 * Safe to re-run: it upserts on Developer Name.
 */
List<Service_Queue__c> queues = new List<Service_Queue__c>{
    new Service_Queue__c(
        Name = 'Customer Service',
        Developer_Name__c = 'CUSTOMER_SERVICE',
        Active__c = true,
        Priority__c = 5,
        Routing_Model__c = 'Least Active',
        Default_Capacity_Weight__c = 1,
        SLA_Minutes__c = 480,
        Push_Timeout_Seconds__c = 45,
        Allow_Manual_Pull__c = true,
        Allow_Decline__c = true,
        Auto_Accept__c = false,
        Max_Queue_Depth_Alert__c = 25,
        Description__c = 'General customer service work. Least Active keeps the load even across the floor.'
    ),
    new Service_Queue__c(
        Name = 'Credit Review',
        Developer_Name__c = 'CREDIT_REVIEW',
        Active__c = true,
        Priority__c = 3,
        Routing_Model__c = 'Skill Based',
        Default_Capacity_Weight__c = 2,
        SLA_Minutes__c = 240,
        Push_Timeout_Seconds__c = 120,
        Allow_Manual_Pull__c = true,
        Allow_Decline__c = false,
        Auto_Accept__c = false,
        Max_Queue_Depth_Alert__c = 10,
        Description__c = 'Credit decisions. Each file counts as two capacity units, agents get two '
            + 'minutes to respond, and declining is off because the work has to land somewhere.'
    ),
    new Service_Queue__c(
        Name = 'Tier 2 Support',
        Developer_Name__c = 'TIER_2_SUPPORT',
        Active__c = true,
        Priority__c = 2,
        Routing_Model__c = 'Most Available',
        Default_Capacity_Weight__c = 1,
        SLA_Minutes__c = 60,
        Push_Timeout_Seconds__c = 30,
        Allow_Manual_Pull__c = true,
        Allow_Decline__c = true,
        Auto_Accept__c = false,
        Max_Queue_Depth_Alert__c = 10,
        Description__c = 'Escalations. Highest queue priority so these are served before general work.'
    )
};

upsert queues Developer_Name__c;
System.debug('Queues ready: ' + queues.size());

// Point Customer Service overflow at Tier 2 after an hour of waiting.
Service_Queue__c cs = [SELECT Id FROM Service_Queue__c WHERE Developer_Name__c = 'CUSTOMER_SERVICE' LIMIT 1];
Service_Queue__c tier2 = [SELECT Id FROM Service_Queue__c WHERE Developer_Name__c = 'TIER_2_SUPPORT' LIMIT 1];
cs.Overflow_Queue__c = tier2.Id;
cs.Overflow_After_Minutes__c = 60;
update cs;
System.debug('Overflow configured: Customer Service -> Tier 2 after 60 minutes');
