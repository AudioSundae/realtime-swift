// Copyright (c) 2021 David Stump <david@davidstump.net>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import Swift

/// Container class of bindings to the channel
struct Binding {
    // The event that the Binding is bound to
    let event: ChannelEvent

    // The reference number of the Binding
    let ref: Int

    // The callback to be triggered
    let callback: Delegated<Message, Void>
}

///
/// Represents a Channel which is bound to a topic
///
/// A Channel can bind to multiple events on a given topic and
/// be informed when those events occur within a topic.
///
/// ### Example:
///
///     let channel = socket.channel("room:123", params: ["token": "Room Token"])
///     channel.on("new_msg") { payload in print("Got message", payload") }
///     channel.push("new_msg, payload: ["body": "This is a message"])
///         .receive("ok") { payload in print("Sent message", payload) }
///         .receive("error") { payload in print("Send failed", payload) }
///         .receive("timeout") { payload in print("Networking issue...", payload) }
///
///     channel.join()
///         .receive("ok") { payload in print("Channel Joined", payload) }
///         .receive("error") { payload in print("Failed ot join", payload) }
///         .receive("timeout") { payload in print("Networking issue...", payload) }
///

import Foundation

public class Channel {
    /// The topic of the Channel. e.g. `.table("rooms", "friends")`
    public let topic: ChannelTopic

    /// The params sent when joining the channel
    public var params: [String: Any] {
        didSet { self.joinPush.payload = params }
    }

    /// The Socket that the channel belongs to
    weak var socket: RealtimeClient?

    /// Current state of the Channel
    var state: ChannelState

    /// Collection of event bindings
    var bindingsDel: [Binding]

    /// Tracks event binding ref counters
    var bindingRef: Int

    /// Timout when attempting to join a Channel
    var timeout: TimeInterval

    /// Set to true once the channel calls .join()
    var joinedOnce: Bool

    /// Push to send when the channel calls .join()
    var joinPush: Push!

    /// Buffer of Pushes that will be sent once the Channel's socket connects
    var pushBuffer: [Push]

    /// Timer to attempt to rejoin
    var rejoinTimer: TimeoutTimer

    /// Refs of stateChange hooks
    var stateChangeRefs: [String]

    /// Initialize a Channel
    ///
    /// - parameter topic: Topic of the Channel
    /// - parameter params: Optional. Parameters to send when joining.
    /// - parameter socket: Socket that the channel is a part of
    init(topic: ChannelTopic, params: [String: Any] = [:], socket: RealtimeClient) {
        state = ChannelState.closed
        self.topic = topic
        self.params = params
        self.socket = socket
        bindingsDel = []
        bindingRef = 0
        timeout = socket.timeout
        joinedOnce = false
        pushBuffer = []
        stateChangeRefs = []
        rejoinTimer = TimeoutTimer()

        // Setup Timer delgation
        rejoinTimer.callback
            .delegate(to: self) { (self) in
                if self.socket?.isConnected == true { self.rejoin() }
            }

        rejoinTimer.timerCalculation
            .delegate(to: self) { (self, tries) -> TimeInterval in
                self.socket?.rejoinAfter(tries) ?? 5.0
            }

        // Respond to socket events
        let onErrorRef = self.socket?.delegateOnError(to: self, callback: { (self, _) in
            self.rejoinTimer.reset()
        })
        if let ref = onErrorRef { stateChangeRefs.append(ref) }

        let onOpenRef = self.socket?.delegateOnOpen(to: self, callback: { (self) in
            self.rejoinTimer.reset()
            if self.isErrored { self.rejoin() }
        })
        if let ref = onOpenRef { stateChangeRefs.append(ref) }

        // Setup Push Event to be sent when joining
        joinPush = Push(channel: self,
                        event: ChannelEvent.join,
                        payload: self.params,
                        timeout: timeout)

        /// Handle when a response is received after join()
        joinPush.delegateReceive("ok", to: self) { (self, _) in
            // Mark the Channel as joined
            self.state = ChannelState.joined

            // Reset the timer, preventing it from attempting to join again
            self.rejoinTimer.reset()

            // Send and buffered messages and clear the buffer
            self.pushBuffer.forEach { $0.send() }
            self.pushBuffer = []
        }

        // Perform if Channel errors while attempting to joi
        joinPush.delegateReceive("error", to: self) { (self, _) in
            self.state = .errored
            if self.socket?.isConnected == true { self.rejoinTimer.scheduleTimeout() }
        }

        // Handle when the join push times out when sending after join()
        joinPush.delegateReceive("timeout", to: self) { (self, _) in
            // log that the channel timed out
            self.socket?.logItems("channel", "timeout \(self.topic) \(self.joinRef ?? "") after \(self.timeout)s")

            // Send a Push to the server to leave the channel
            let leavePush = Push(channel: self,
                                 event: ChannelEvent.leave,
                                 timeout: self.timeout)
            leavePush.send()

            // Mark the Channel as in an error and attempt to rejoin if socket is connected
            self.state = ChannelState.errored
            self.joinPush.reset()

            if self.socket?.isConnected == true { self.rejoinTimer.scheduleTimeout() }
        }

        /// Perfom when the Channel has been closed
        delegateOnClose(to: self) { (self, _) in
            // Reset any timer that may be on-going
            self.rejoinTimer.reset()

            // Log that the channel was left
            self.socket?.logItems("channel", "close topic: \(self.topic) joinRef: \(self.joinRef ?? "nil")")

            // Mark the channel as closed and remove it from the socket
            self.state = ChannelState.closed
            self.socket?.remove(self)
        }

        /// Perfom when the Channel errors
        delegateOnError(to: self) { (self, message) in
            // Log that the channel received an error
            self.socket?.logItems("channel", "error topic: \(self.topic) joinRef: \(self.joinRef ?? "nil") mesage: \(message)")

            // If error was received while joining, then reset the Push
            if self.isJoining {
                // Make sure that the "phx_join" isn't buffered to send once the socket
                // reconnects. The channel will send a new join event when the socket connects.
                if let safeJoinRef = self.joinRef {
                    self.socket?.removeFromSendBuffer(ref: safeJoinRef)
                }

                // Reset the push to be used again later
                self.joinPush.reset()
            }

            // Mark the channel as errored and attempt to rejoin if socket is currently connected
            self.state = ChannelState.errored
            if self.socket?.isConnected == true { self.rejoinTimer.scheduleTimeout() }
        }

        // Perform when the join reply is received
        delegateOn(ChannelEvent.reply, to: self) { (self, message) in
            // Trigger bindings
            self.trigger(event: ChannelEvent.channelReply(message.ref),
                         payload: message.payload,
                         ref: message.ref,
                         joinRef: message.joinRef)
        }
    }

    deinit {
        rejoinTimer.reset()
    }

    /// Overridable message hook. Receives all events for specialized message
    /// handling before dispatching to the channel callbacks.
    ///
    /// - parameter msg: The Message received by the client from the server
    /// - return: Must return the message, modified or unmodified
    public var onMessage: (_ message: Message) -> Message = { message in
        message
    }

    /// Joins the channel
    ///
    /// - parameter timeout: Optional. Defaults to Channel's timeout
    /// - return: Push event
    @discardableResult
    public func subscribe(timeout: TimeInterval? = nil) -> Push {
        guard !joinedOnce else {
            fatalError("tried to join multiple times. 'join' "
                + "can only be called a single time per channel instance")
        }

        // Join the Channel
        if let safeTimeout = timeout { self.timeout = safeTimeout }

        joinedOnce = true
        rejoin()
        return joinPush
    }

    /// Hook into when the Channel is closed. Does not handle retain cycles.
    /// Use `delegateOnClose(to:)` for automatic handling of retain cycles.
    ///
    /// Example:
    ///
    ///     let channel = socket.channel("topic")
    ///     channel.onClose() { [weak self] message in
    ///         self?.print("Channel \(message.topic) has closed"
    ///     }
    ///
    /// - parameter callback: Called when the Channel closes
    /// - return: Ref counter of the subscription. See `func off()`
    @discardableResult
    public func onClose(_ callback: @escaping ((Message) -> Void)) -> Int {
        return on(ChannelEvent.close, callback: callback)
    }

    /// Hook into when the Channel is closed. Automatically handles retain
    /// cycles. Use `onClose()` to handle yourself.
    ///
    /// Example:
    ///
    ///     let channel = socket.channel("topic")
    ///     channel.delegateOnClose(to: self) { (self, message) in
    ///         self.print("Channel \(message.topic) has closed"
    ///     }
    ///
    /// - parameter owner: Class registering the callback. Usually `self`
    /// - parameter callback: Called when the Channel closes
    /// - return: Ref counter of the subscription. See `func off()`
    @discardableResult
    public func delegateOnClose<Target: AnyObject>(to owner: Target,
                                                   callback: @escaping ((Target, Message) -> Void)) -> Int
    {
        return delegateOn(ChannelEvent.close, to: owner, callback: callback)
    }

    /// Hook into when the Channel receives an Error. Does not handle retain
    /// cycles. Use `delegateOnError(to:)` for automatic handling of retain
    /// cycles.
    ///
    /// Example:
    ///
    ///     let channel = socket.channel("topic")
    ///     channel.onError() { [weak self] (message) in
    ///         self?.print("Channel \(message.topic) has errored"
    ///     }
    ///
    /// - parameter callback: Called when the Channel closes
    /// - return: Ref counter of the subscription. See `func off()`
    @discardableResult
    public func onError(_ callback: @escaping ((_ message: Message) -> Void)) -> Int {
        return on(ChannelEvent.error, callback: callback)
    }

    /// Hook into when the Channel receives an Error. Automatically handles
    /// retain cycles. Use `onError()` to handle yourself.
    ///
    /// Example:
    ///
    ///     let channel = socket.channel("topic")
    ///     channel.delegateOnError(to: self) { (self, message) in
    ///         self.print("Channel \(message.topic) has closed"
    ///     }
    ///
    /// - parameter owner: Class registering the callback. Usually `self`
    /// - parameter callback: Called when the Channel closes
    /// - return: Ref counter of the subscription. See `func off()`
    @discardableResult
    public func delegateOnError<Target: AnyObject>(to owner: Target,
                                                   callback: @escaping ((Target, Message) -> Void)) -> Int
    {
        return delegateOn(ChannelEvent.error, to: owner, callback: callback)
    }

    /// Subscribes on channel events. Does not handle retain cycles. Use
    /// `delegateOn(_:, to:)` for automatic handling of retain cycles.
    ///
    /// Subscription returns a ref counter, which can be used later to
    /// unsubscribe the exact event listener
    ///
    /// Example:
    ///
    ///     let channel = socket.channel("topic")
    ///     let ref1 = channel.on(.all) { [weak self] (message) in
    ///         self?.print("do stuff")
    ///     }
    ///     let ref2 = channel.on(.all) { [weak self] (message) in
    ///         self?.print("do other stuff")
    ///     }
    ///     channel.off(.all, ref1)
    ///
    /// Since unsubscription of ref1, "do stuff" won't print, but "do other
    /// stuff" will keep on printing on the "event"
    ///
    /// - parameter event: Event to receive
    /// - parameter callback: Called with the event's message
    /// - return: Ref counter of the subscription. See `func off()`
    @discardableResult
    public func on(_ event: ChannelEvent, callback: @escaping ((Message) -> Void)) -> Int {
        var delegated = Delegated<Message, Void>()
        delegated.manuallyDelegate(with: callback)

        return on(event, delegated: delegated)
    }

    /// Subscribes on channel events. Automatically handles retain cycles. Use
    /// `on()` to handle yourself.
    ///
    /// Subscription returns a ref counter, which can be used later to
    /// unsubscribe the exact event listener
    ///
    /// Example:
    ///
    ///     let channel = socket.channel("topic")
    ///     let ref1 = channel.delegateOn(.all, to: self) { (self, message) in
    ///         self?.print("do stuff")
    ///     }
    ///     let ref2 = channel.delegateOn(.all, to: self) { (self, message) in
    ///         self?.print("do other stuff")
    ///     }
    ///     channel.off(.all, ref1)
    ///
    /// Since unsubscription of ref1, "do stuff" won't print, but "do other
    /// stuff" will keep on printing on all "event" (*).
    ///
    /// - parameter event: Event to receive
    /// - parameter owner: Class registering the callback. Usually `self`
    /// - parameter callback: Called with the event's message
    /// - return: Ref counter of the subscription. See `func off()`
    @discardableResult
    public func delegateOn<Target: AnyObject>(_ event: ChannelEvent,
                                              to owner: Target,
                                              callback: @escaping ((Target, Message) -> Void)) -> Int
    {
        var delegated = Delegated<Message, Void>()
        delegated.delegate(to: owner, with: callback)

        return on(event, delegated: delegated)
    }

    /// Shared method between `on` and `manualOn`
    @discardableResult
    private func on(_ event: ChannelEvent, delegated: Delegated<Message, Void>) -> Int {
        let ref = bindingRef
        bindingRef = ref + 1

        bindingsDel.append(Binding(event: event, ref: ref, callback: delegated))
        return ref
    }

    /// Unsubscribes from a channel event. If a `ref` is given, only the exact
    /// listener will be removed. Else all listeners for the `event` will be
    /// removed.
    ///
    /// Example:
    ///
    ///     let channel = socket.channel("topic")
    ///     let ref1 = channel.on(.insert) { _ in print("ref1 event" }
    ///     let ref2 = channel.on(.insert) { _ in print("ref2 event" }
    ///     let ref3 = channel.on(.update) { _ in print("ref3 other" }
    ///     let ref4 = channel.on(.update) { _ in print("ref4 other" }
    ///     channel.off(.insert, ref1)
    ///     channel.off(.update)
    ///
    /// After this, only "ref2 event" will be printed if the channel receives
    /// "insert" and nothing is printed if the channel receives "update".
    ///
    /// - parameter event: Event to unsubscribe from
    /// - paramter ref: Ref counter returned when subscribing. Can be omitted
    public func off(_ event: ChannelEvent, ref: Int? = nil) {
        bindingsDel.removeAll { (bind) -> Bool in
            bind.event == event && (ref == nil || ref == bind.ref)
        }
    }

    /// Push a payload to the Channel
    ///
    /// Example:
    ///
    ///     channel
    ///         .push(.update, payload: ["message": "hello")
    ///         .receive("ok") { _ in { print("message sent") }
    ///
    /// - parameter event: Event to push
    /// - parameter payload: Payload to push
    /// - parameter timeout: Optional timeout
    @discardableResult
    public func push(_ event: ChannelEvent,
                     payload: [String: Any],
                     timeout: TimeInterval = Defaults.timeoutInterval) -> Push
    {
        guard joinedOnce else { fatalError("Tried to push \(event) to \(topic) before joining. Use channel.join() before pushing events") }

        let pushEvent = Push(channel: self,
                             event: event,
                             payload: payload,
                             timeout: timeout)
        if canPush {
            pushEvent.send()
        } else {
            pushEvent.startTimeout()
            pushBuffer.append(pushEvent)
        }

        return pushEvent
    }

    /// Leaves the channel
    ///
    /// Unsubscribes from server events, and instructs channel to terminate on
    /// server
    ///
    /// Triggers onClose() hooks
    ///
    /// To receive leave acknowledgements, use the a `receive`
    /// hook to bind to the server ack, ie:
    ///
    /// Example:
    ////
    ///     channel.unsubscribe().receive("ok") { _ in { print("left") }
    ///
    /// - parameter timeout: Optional timeout
    /// - return: Push that can add receive hooks
    @discardableResult
    public func unsubscribe(timeout: TimeInterval = Defaults.timeoutInterval) -> Push {
        // If attempting a rejoin during a leave, then reset, cancelling the rejoin
        rejoinTimer.reset()

        // Now set the state to leaving
        state = .leaving

        /// Delegated callback for a successful or a failed channel leave
        var onCloseDelegate = Delegated<Message, Void>()
        onCloseDelegate.delegate(to: self) { (self, _) in
            self.socket?.logItems("channel", "leave \(self.topic)")

            // Triggers onClose() hooks
            self.trigger(event: ChannelEvent.close, payload: ["reason": "leave"])
        }

        // Push event to send to the server
        let leavePush = Push(channel: self,
                             event: ChannelEvent.leave,
                             timeout: timeout)

        // Perform the same behavior if successfully left the channel
        // or if sending the event timed out
        leavePush
            .receive("ok", delegated: onCloseDelegate)
            .receive("timeout", delegated: onCloseDelegate)
        leavePush.send()

        // If the Channel cannot send push events, trigger a success locally
        if !canPush { leavePush.trigger("ok", payload: [:]) }

        // Return the push so it can be bound to
        return leavePush
    }

    /// Overridable message hook. Receives all events for specialized message
    /// handling before dispatching to the channel callbacks.
    ///
    /// - parameter event: The event the message was for
    /// - parameter payload: The payload for the message
    /// - parameter ref: The reference of the message
    /// - return: Must return the payload, modified or unmodified
    public func onMessage(callback: @escaping (Message) -> Message) {
        onMessage = callback
    }

    // ----------------------------------------------------------------------

    // MARK: - Internal

    // ----------------------------------------------------------------------
    /// Checks if an event received by the Socket belongs to this Channel
    func isMember(_ message: Message) -> Bool {
        // Return false if the message's topic does not match the Channel's topic
        guard message.topic == topic else { return false }

        guard
            let safeJoinRef = message.joinRef,
            safeJoinRef != joinRef,
            ChannelEvent.isLifecyleEvent(message.event)
        else { return true }

        socket?.logItems("channel", "dropping outdated message", message.topic, message.event, message.payload, safeJoinRef)
        return false
    }

    /// Sends the payload to join the Channel
    func sendJoin(_ timeout: TimeInterval) {
        state = ChannelState.joining
        joinPush.resend(timeout)
    }

    /// Rejoins the channel
    func rejoin(_ timeout: TimeInterval? = nil) {
        // Do not attempt to rejoin if the channel is in the process of leaving
        guard !isLeaving else { return }

        // Leave potentially duplicate channels
        socket?.leaveOpenTopic(topic: topic)

        // Send the joinPush
        sendJoin(timeout ?? self.timeout)
    }

    /// Triggers an event to the correct event bindings created by
    /// `channel.on("event")`.
    ///
    /// - parameter message: Message to pass to the event bindings
    func trigger(_ message: Message) {
        let handledMessage = onMessage(message)

        bindingsDel
            .filter { $0.event == message.event }
            .forEach { $0.callback.call(handledMessage) }
    }

    /// Triggers an event to the correct event bindings created by
    //// `channel.on(event)`.
    ///
    /// - parameter event: Event to trigger
    /// - parameter payload: Payload of the event
    /// - parameter ref: Ref of the event. Defaults to empty
    /// - parameter joinRef: Ref of the join event. Defaults to nil
    func trigger(event: ChannelEvent,
                 payload: [String: Any] = [:],
                 ref: String = "",
                 joinRef: String? = nil)
    {
        let message = Message(ref: ref,
                              topic: topic,
                              event: event,
                              payload: payload,
                              joinRef: joinRef ?? self.joinRef)
        trigger(message)
    }

    /// The Ref send during the join message.
    var joinRef: String? {
        return joinPush.ref
    }

    /// - return: True if the Channel can push messages, meaning the socket
    ///           is connected and the channel is joined
    var canPush: Bool {
        return socket?.isConnected == true && isJoined
    }
}

// ----------------------------------------------------------------------

// MARK: - Public API

// ----------------------------------------------------------------------
public extension Channel {
    /// - return: True if the Channel has been closed
    var isClosed: Bool {
        return state == .closed
    }

    /// - return: True if the Channel experienced an error
    var isErrored: Bool {
        return state == .errored
    }

    /// - return: True if the channel has joined
    var isJoined: Bool {
        return state == .joined
    }

    /// - return: True if the channel has requested to join
    var isJoining: Bool {
        return state == .joining
    }

    /// - return: True if the channel has requested to leave
    var isLeaving: Bool {
        return state == .leaving
    }
}
