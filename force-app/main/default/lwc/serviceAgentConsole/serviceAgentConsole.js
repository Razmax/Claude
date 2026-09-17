import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import USER_ID from '@salesforce/user/Id';

import refreshConsoleState from '@salesforce/apex/ServiceRoutingConsoleController.refreshConsoleState';
import setPresence from '@salesforce/apex/ServiceRoutingConsoleController.setPresence';
import acceptWork from '@salesforce/apex/ServiceRoutingConsoleController.acceptWork';
import declineWork from '@salesforce/apex/ServiceRoutingConsoleController.declineWork';
import completeWork from '@salesforce/apex/ServiceRoutingConsoleController.completeWork';
import pullWork from '@salesforce/apex/ServiceRoutingConsoleController.pullWork';
import transferWork from '@salesforce/apex/ServiceRoutingConsoleController.transferWork';
import getTransferQueues from '@salesforce/apex/ServiceRoutingConsoleController.getTransferQueues';

const CHANNEL = '/event/Service_Work_Assigned__e';
const POLL_INTERVAL_MS = 30000;
const TICK_INTERVAL_MS = 1000;

export default class ServiceAgentConsole extends NavigationMixin(LightningElement) {
    @track state = {
        presenceLabel: 'Not set',
        presenceOptions: [],
        myWork: [],
        availableWork: [],
        currentLoad: 0,
        maxCapacity: 0,
        routingEnabled: true
    };

    loading = false;
    showTransfer = false;
    transferQueues = [];
    transferQueueId;
    transferReason = '';
    transferItemId;

    subscription;
    pollTimer;
    tickTimer;

    // ------------------------------------------------------------------ lifecycle

    connectedCallback() {
        this.load();
        this.subscribeToAssignments();
        // Platform events cover the interesting moments; the poll is a safety net for
        // timeouts and other agents' actions that this user never hears about.
        this.pollTimer = setInterval(() => this.load(true), POLL_INTERVAL_MS);
        this.tickTimer = setInterval(() => this.tickCountdowns(), TICK_INTERVAL_MS);
    }

    disconnectedCallback() {
        clearInterval(this.pollTimer);
        clearInterval(this.tickTimer);
        if (this.subscription) {
            unsubscribe(this.subscription, () => {});
            this.subscription = undefined;
        }
    }

    subscribeToAssignments() {
        onError((error) => {
            // A dropped streaming connection degrades to polling rather than breaking.
            // eslint-disable-next-line no-console
            console.error('Service routing streaming error', JSON.stringify(error));
        });
        subscribe(CHANNEL, -1, (message) => {
            const payload = message?.data?.payload || {};
            const forMe = payload.User_Id__c && payload.User_Id__c.startsWith(USER_ID.substring(0, 15));
            if (forMe || payload.Action__c === 'Recalled') {
                this.load(true);
                if (forMe && payload.Action__c === 'Assigned') {
                    this.notify('New work assigned', payload.Work_Item_Number__c || '', 'info');
                }
            }
        }).then((response) => {
            this.subscription = response;
        });
    }

    // ------------------------------------------------------------------ data

    async load(silent = false) {
        if (!silent) {
            this.loading = true;
        }
        try {
            const result = await refreshConsoleState();
            this.applyState(result);
        } catch (error) {
            if (!silent) {
                this.notify('Could not load your work list', this.messageOf(error), 'error');
            }
        } finally {
            this.loading = false;
        }
    }

    /**
     * Apex returns read-only objects, so decorate copies. secondsLeft is recomputed on a
     * timer from the server-supplied expiry rather than counted down locally, which keeps
     * the display honest if the tab was backgrounded.
     */
    applyState(result) {
        const decorate = (items) =>
            (items || []).map((item) => ({
                ...item,
                secondsLeft: this.secondsUntil(item.pushExpiresAt)
            }));
        this.state = {
            ...result,
            myWork: decorate(result.myWork),
            availableWork: decorate(result.availableWork)
        };
    }

    tickCountdowns() {
        if (!this.state.myWork || this.state.myWork.length === 0) {
            return;
        }
        let expiredSomething = false;
        const updated = this.state.myWork.map((item) => {
            const secondsLeft = this.secondsUntil(item.pushExpiresAt);
            if (item.canAccept && item.secondsLeft > 0 && secondsLeft <= 0) {
                expiredSomething = true;
            }
            return { ...item, secondsLeft };
        });
        this.state = { ...this.state, myWork: updated };
        if (expiredSomething) {
            // The server times the item out; refresh to pick up where it landed.
            this.load(true);
        }
    }

    secondsUntil(isoDatetime) {
        if (!isoDatetime) {
            return 0;
        }
        const remaining = Math.floor((new Date(isoDatetime).getTime() - Date.now()) / 1000);
        return remaining > 0 ? remaining : 0;
    }

    // ------------------------------------------------------------------ actions

    async runAction(promise, successMessage) {
        this.loading = true;
        try {
            const result = await promise;
            this.applyState(result);
            if (successMessage) {
                this.notify(successMessage, '', 'success');
            }
        } catch (error) {
            this.notify('That did not work', this.messageOf(error), 'error');
        } finally {
            this.loading = false;
        }
    }

    handlePresenceSelect(event) {
        const status = event.detail.value;
        const option = this.state.presenceOptions.find((o) => o.developerName === status);
        let reason = null;
        if (option && option.requiresReason) {
            // eslint-disable-next-line no-alert
            reason = window.prompt(`Reason for ${option.label}`);
            if (!reason) {
                return;
            }
        }
        this.runAction(setPresence({ statusDeveloperName: status, reason }), null);
    }

    handleAccept(event) {
        this.runAction(acceptWork({ workItemId: event.currentTarget.dataset.id }), 'Accepted');
    }

    handleDecline(event) {
        // eslint-disable-next-line no-alert
        const reason = window.prompt('Why are you declining this?') || 'Declined by agent';
        this.runAction(declineWork({ workItemId: event.currentTarget.dataset.id, reason }), 'Sent back to the queue');
    }

    handleComplete(event) {
        this.runAction(
            completeWork({ workItemId: event.currentTarget.dataset.id, closeReason: 'Resolved' }),
            'Completed'
        );
    }

    handlePull(event) {
        this.runAction(pullWork({ workItemId: event.currentTarget.dataset.id }), 'Picked up');
    }

    handleOpenRecord(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: event.currentTarget.dataset.record,
                actionName: 'view'
            }
        });
    }

    // ------------------------------------------------------------------ transfer

    async handleTransfer(event) {
        this.transferItemId = event.currentTarget.dataset.id;
        this.transferQueueId = event.currentTarget.dataset.queue;
        this.transferReason = '';
        if (this.transferQueues.length === 0) {
            try {
                this.transferQueues = await getTransferQueues();
            } catch (error) {
                this.notify('Could not load queues', this.messageOf(error), 'error');
                return;
            }
        }
        this.showTransfer = true;
    }

    handleTransferQueueChange(event) {
        this.transferQueueId = event.detail.value;
    }

    handleTransferReasonChange(event) {
        this.transferReason = event.detail.value;
    }

    closeTransfer() {
        this.showTransfer = false;
    }

    confirmTransfer() {
        if (!this.transferQueueId) {
            this.notify('Pick a queue first', '', 'warning');
            return;
        }
        this.showTransfer = false;
        this.runAction(
            transferWork({
                workItemId: this.transferItemId,
                targetQueueId: this.transferQueueId,
                targetAgentId: null,
                reason: this.transferReason
            }),
            'Transferred'
        );
    }

    // ------------------------------------------------------------------ getters

    get hasMyWork() {
        return this.state.myWork && this.state.myWork.length > 0;
    }

    get hasAvailableWork() {
        return this.state.availableWork && this.state.availableWork.length > 0;
    }

    get myWorkLabel() {
        return `My Work (${this.state.myWork ? this.state.myWork.length : 0})`;
    }

    get availableLabel() {
        return `Queue (${this.state.availableWork ? this.state.availableWork.length : 0})`;
    }

    get routingDisabled() {
        return this.state.routingEnabled === false;
    }

    get presenceDotStyle() {
        return `background-color: ${this.state.presenceColor || '#706e6b'};`;
    }

    get capacityStyle() {
        const max = this.state.maxCapacity || 0;
        const load = this.state.currentLoad || 0;
        const percent = max > 0 ? Math.min(100, Math.round((load / max) * 100)) : 0;
        const color = percent >= 100 ? '#ba0517' : percent >= 75 ? '#a6690d' : '#2e844a';
        return `width: ${percent}%; background-color: ${color};`;
    }

    // ------------------------------------------------------------------ helpers

    messageOf(error) {
        return error?.body?.message || error?.message || 'Unexpected error';
    }

    notify(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
