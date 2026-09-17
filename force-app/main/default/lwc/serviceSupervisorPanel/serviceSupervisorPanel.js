import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import refreshDashboard from '@salesforce/apex/ServiceSupervisorController.refreshDashboard';
import routeNow from '@salesforce/apex/ServiceSupervisorController.routeNow';
import resyncCapacity from '@salesforce/apex/ServiceSupervisorController.resyncCapacity';

const REFRESH_INTERVAL_MS = 30000;

export default class ServiceSupervisorPanel extends LightningElement {
    @track dashboard = { queues: [], agents: [], unroutedCount: 0, routingEnabled: true };
    loading = false;
    refreshTimer;

    connectedCallback() {
        this.load();
        this.refreshTimer = setInterval(() => this.load(true), REFRESH_INTERVAL_MS);
    }

    disconnectedCallback() {
        clearInterval(this.refreshTimer);
    }

    async load(silent = false) {
        if (!silent) {
            this.loading = true;
        }
        try {
            const result = await refreshDashboard();
            this.dashboard = {
                ...result,
                queues: (result.queues || []).map((queue) => ({
                    ...queue,
                    rowClass: queue.overThreshold ? 'queue-alert' : ''
                })),
                agents: (result.agents || []).map((agent) => ({
                    ...agent,
                    dotStyle: `background-color: ${agent.presenceColor || '#706e6b'};`,
                    loadLabel: `${agent.currentLoad} / ${agent.maxCapacity}`
                }))
            };
        } catch (error) {
            if (!silent) {
                this.notify('Could not load the dashboard', this.messageOf(error), 'error');
            }
        } finally {
            this.loading = false;
        }
    }

    handleRefresh() {
        this.load();
    }

    async handleRouteNow() {
        await this.runAction(routeNow({ queueId: null }));
    }

    async handleRouteQueue(event) {
        await this.runAction(routeNow({ queueId: event.currentTarget.dataset.queue }));
    }

    async handleResync() {
        await this.runAction(resyncCapacity());
    }

    async runAction(promise) {
        this.loading = true;
        try {
            const message = await promise;
            this.notify('Done', message, 'success');
            await this.load(true);
        } catch (error) {
            this.notify('That did not work', this.messageOf(error), 'error');
        } finally {
            this.loading = false;
        }
    }

    get routingDisabled() {
        return this.dashboard.routingEnabled === false;
    }

    get hasUnrouted() {
        return this.dashboard.unroutedCount > 0;
    }

    messageOf(error) {
        return error?.body?.message || error?.message || 'Unexpected error';
    }

    notify(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
