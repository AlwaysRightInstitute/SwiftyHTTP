//
//  Socket.swift
//  SwiftSockets
//
//  Created by Helge Heß on 6/9/14.
//  Copyright (c) 2014-2015 Always Right Institute. All rights reserved.
//

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Dispatch

/**
 * Simple Socket classes for Swift.
 *
 * PassiveSockets are 'listening' sockets, ActiveSockets are open connections.
 */
open class Socket<T: SocketAddress> {
  
  open var fd           : FileDescriptor = nil
  open var boundAddress : T?      = nil
  open var isValid      : Bool { return fd.isValid }
  open var isBound      : Bool { return boundAddress != nil }
  
  var closeCB  : ((FileDescriptor) -> Void)? = nil
  var closedFD : FileDescriptor? = nil // for delayed callback
  
  
  /* initializer / deinitializer */
  
  public init(fd: FileDescriptor) {
    self.fd = fd
  }
  deinit {
    close() // TBD: is this OK/safe?
  }
  
  public convenience init?(type: Int32 = sys_SOCK_STREAM) {
    let   lfd  = socket(T.domain, type, 0)
    guard lfd != -1 else { return nil }
    
    self.init(fd: FileDescriptor(lfd))
  }
  
  
  /* explicitly close the socket */
  
  let debugClose = false
  
  open func close() {
    if fd.isValid {
      closedFD = fd
      if debugClose { print("Closing socket", closedFD as Any, "for good ...") }
      fd.close()
      fd       = nil
      
      if let cb = closeCB {
        // can be used to unregister socket etc when the socket is really closed
        if debugClose { print("  let closeCB", closedFD as Any, "know ...") }
        cb(closedFD!)
        closeCB = nil // break potential cycles
      }
      if debugClose { print("done closing", closedFD as Any) }
    }
    else if debugClose {
      print("socket", closedFD as Any, "already closed.")
    }
    
    boundAddress = nil
  }
  
  @discardableResult
  open func onClose(_ cb: ((FileDescriptor) -> Void)?) -> Self {
    if let fd = closedFD { // socket got closed before event-handler attached
      if let lcb = cb {
        lcb(fd)
      }
      else {
        closeCB = nil
      }
    }
    else {
      closeCB = cb
    }
    return self
  }
  
  
  /* bind the socket. */
  
  open func bind(_ address: T) -> Bool {
    guard fd.isValid else { return false }
    
    guard !isBound else {
      print("Socket is already bound!")
      return false
    }
    
    // Note: must be 'var' for ptr stuff, can't use let
    var addr = address
    let len  = socklen_t(addr.len)

    let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
      return ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bptr in
        return sysBind(fd.fd, bptr, len)
      }
    }
    
    if rc == 0 {
      // Generics TBD: cannot check for isWildcardPort, always grab the name
      boundAddress = getsockname()
      /* if it was a wildcard port bind, get the address */
      // boundAddress = addr.isWildcardPort ? getsockname() : addr
    }
    
    return rc == 0
  }
  
  open func getsockname() -> T? {
    return _getaname(sysGetsockname)
  }
  open func getpeername() -> T? {
    return _getaname(sysGetpeername)
  }
  
  typealias GetNameFN = ( Int32, UnsafeMutablePointer<sockaddr>,
                          UnsafeMutablePointer<socklen_t>) -> Int32
  func _getaname(_ nfn: GetNameFN) -> T? {
    guard fd.isValid else { return nil }
    
    // FIXME: tried to encapsulate this in a sockaddrbuf which does all the
    //        ptr handling, but it ain't work (autoreleasepool issue?)
    var baddr    = T()
    var baddrlen = socklen_t(baddr.len)
    
    // Note: we are not interested in the length here, would be relevant
    //       for AF_UNIX sockets
    let rc = withUnsafeMutablePointer(to: &baddr) { ptr -> Int32 in
      return ptr.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) {
        bptr in
        return nfn(fd.fd, bptr, &baddrlen)
      }
    }
    
    guard rc == 0 else {
      print("Could not get sockname? \(rc)")
      return nil
    }
    
    // print("PORT: \(baddr.sin_port)")
    return baddr
  }
  
  
  /* description */
  
  // must live in the main-class as 'declarations in extensions cannot be
  // overridden yet' (Same in Swift 2.0)
  func descriptionAttributes() -> String {
    var s = fd.isValid
      ? " fd=\(fd.fd)"
      : (closedFD != nil ? " closed[\(closedFD!)]" :" not-open")
    if boundAddress != nil {
      s += " \(boundAddress!)"
    }
    return s
  }
  
}


extension Socket { // Socket Flags
  
  public var flags : Int32? {
    get { return fd.flags      }
    set { fd.flags = newValue! }
  }
  
  public var isNonBlocking : Bool {
    get { return fd.isNonBlocking }
    set { fd.isNonBlocking = newValue }
  }
  
}

extension Socket { // Socket Options

  public var reuseAddress: Bool {
    get { return getSocketOption(SO_REUSEADDR) }
    set { _ = setSocketOption(SO_REUSEADDR, value: newValue) }
  }

#if os(Linux)
  // No: SO_NOSIGPIPE on Linux, use MSG_NOSIGNAL in send()
  public var isSigPipeDisabled: Bool {
    get { return false }
    set { /* DANGER, DANGER, ALERT */ }
  }
#else
  public var isSigPipeDisabled: Bool {
    get { return getSocketOption(SO_NOSIGPIPE) }
    set { _ = setSocketOption(SO_NOSIGPIPE, value: newValue) }
  }
#endif

  public var keepAlive: Bool {
    get { return getSocketOption(SO_KEEPALIVE) }
    set { _ = setSocketOption(SO_KEEPALIVE, value: newValue) }
  }
  public var dontRoute: Bool {
    get { return getSocketOption(SO_DONTROUTE) }
    set { _ = setSocketOption(SO_DONTROUTE, value: newValue) }
  }
  public var socketDebug: Bool {
    get { return getSocketOption(SO_DEBUG) }
    set { _ = setSocketOption(SO_DEBUG, value: newValue) }
  }
  
  public var sendBufferSize: Int32 {
    get { return getSocketOption(SO_SNDBUF) ?? -42    }
    set { _ = setSocketOption(SO_SNDBUF, value: newValue) }
  }
  public var receiveBufferSize: Int32 {
    get { return getSocketOption(SO_RCVBUF) ?? -42    }
    set { _ = setSocketOption(SO_RCVBUF, value: newValue) }
  }
  public var socketError: Int32 {
    return getSocketOption(SO_ERROR) ?? -42
  }
  
  /* socket options (TBD: would we use subscripts for such?) */
  
  public func setSocketOption(_ option: Int32, value: Int32) -> Bool {
    if !isValid {
      return false
    }
    
    var buf = value
    let rc  = setsockopt(fd.fd, SOL_SOCKET, option,
                         &buf, socklen_t(MemoryLayout<Int32>.size))
    
    if rc != 0 { // ps: Great Error Handling
      print("Could not set option \(option) on socket \(self)")
    }
    return rc == 0
  }
  
  // TBD: Can't overload optionals in a useful way?
  // func getSocketOption(option: Int32) -> Int32
  public func getSocketOption(_ option: Int32) -> Int32? {
    if !isValid {
      return nil
    }
    
    var buf    = Int32(0)
    var buflen = socklen_t(MemoryLayout<Int32>.size)
    
    let rc = getsockopt(fd.fd, SOL_SOCKET, option, &buf, &buflen)
    if rc != 0 { // ps: Great Error Handling
      print("Could not get option \(option) from socket \(self)")
      return nil
    }
    return buf
  }
  
  public func setSocketOption(_ option: Int32, value: Bool) -> Bool {
    return setSocketOption(option, value: value ? 1 : 0)
  }
  public func getSocketOption(_ option: Int32) -> Bool {
    let v: Int32? = getSocketOption(option)
    return v != nil ? (v! == 0 ? false : true) : false
  }
  
}


extension Socket { // poll()
  
  public var isDataAvailable: Bool { return fd.isDataAvailable }
  
  public func pollFlag(_ flag: Int32) -> Bool { return fd.pollFlag(flag) }
  
  public func poll(_ events: Int32, timeout: UInt? = 0) -> Int32? {
    return fd.poll(events, timeout: timeout)
  }
  
}


extension Socket: CustomStringConvertible {
  
  public var description : String {
    return "<Socket:" + descriptionAttributes() + ">"
  }
  
}


extension Socket { // TBD: Swift doesn't want us to do this
  
  public var boolValue : Bool {
    return isValid
  }
  
}
