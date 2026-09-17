/**
 * Resolves the strategy for a queue: explicit Apex class first, then the queue's routing
 * model, then the org default, then Least Active.
 */
public with sharing class RoutingStrategyFactory {
    private static final Map<String, String> MODEL_TO_CLASS = new Map<String, String>{
        'Least Active'   => 'LeastActiveRoutingStrategy',
        'Most Available' => 'MostAvailableRoutingStrategy',
        'Round Robin'    => 'RoundRobinRoutingStrategy',
        'Skill Based'    => 'SkillBasedRoutingStrategy'
    };

    private static Map<String, IRoutingStrategy> cache = new Map<String, IRoutingStrategy>();

    public static IRoutingStrategy forQueue(Service_Queue__c queue) {
        String className = resolveClassName(queue);
        IRoutingStrategy strategy = cache.get(className);
        if (strategy != null) {
            return strategy;
        }
        strategy = instantiate(className);
        if (strategy == null) {
            // A bad class name on one queue must not stop the rest of the org routing.
            strategy = new LeastActiveRoutingStrategy();
        }
        cache.put(className, strategy);
        return strategy;
    }

    private static String resolveClassName(Service_Queue__c queue) {
        if (queue != null && String.isNotBlank(queue.Routing_Strategy_Class__c)) {
            return queue.Routing_Strategy_Class__c.trim();
        }
        if (queue != null && MODEL_TO_CLASS.containsKey(queue.Routing_Model__c)) {
            return MODEL_TO_CLASS.get(queue.Routing_Model__c);
        }
        String orgDefault = RoutingSettings.get().Default_Strategy_Class__c;
        return String.isNotBlank(orgDefault) ? orgDefault.trim() : 'LeastActiveRoutingStrategy';
    }

    private static IRoutingStrategy instantiate(String className) {
        try {
            Type t = Type.forName(className);
            if (t == null) {
                return null;
            }
            Object instance = t.newInstance();
            return instance instanceof IRoutingStrategy ? (IRoutingStrategy) instance : null;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Cannot instantiate routing strategy ' + className + ': ' + e.getMessage());
            return null;
        }
    }

    @TestVisible
    private static void register(String className, IRoutingStrategy strategy) {
        cache.put(className, strategy);
    }
}
