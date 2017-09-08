//
//  PassiveSocket.swift
//  SwiftSockets
//
//  Created by Helge Hess on 6/11/14.
//  Copyright (c) 2014-2015 Always Right Institute. All rights reserved.
//

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Dispatch

public typealias PassiveSocketIPv4 = PassiveSocket<sockaddr_in>

/*
 * Represents a STREAM server socket based on the standard Unix sockets library.
 *
 * A passive socket has exactly one address, the address the socket is bound to.
 * If you do not bind the socket, the address is determined after the listen()
 * call was executed through the getsockname() call.
 *
 * Note that if the socket is bound it's still an active socket from the
 * system's PoV, it becomes an passive one when the listen call is executed.
 *
 * Sample:
 *
 *   let socket = PassiveSocket(address: sockaddr_in(port: 4242))
 *
 *   socket.listen(dispatch_get_global_queue(0, 0), backlog: 5) {
 *     print("Wait, someone is attempting to talk to me!")
 *     $0.close()
 *     print("All good, go ahead!")
 *   }
 */
open class PassiveSocket<T: SocketAddress>: Socket<T> {
  
  open var backlog      : Int? = nil
  open var isListening  : Bool { return backlog != nil }
  open var listenSource : DispatchSource? = nil
  
  /* init */
  // The overloading behaviour gets more weird every release?

  override public init(fd: FileDescriptor) {
    // required, otherwise the convenience one fails to compile
    super.init(fd: fd)
  }
  
  public convenience init?(address: T) {
    // does not work anymore in b5?: I again need to copy&paste
    // self.init(type: SOCK_STREAM)
    // DUPE:
    let lfd = socket(T.domain, sys_SOCK_STREAM, 0)
    guard lfd != -1 else { return nil }

    self.init(fd: FileDescriptor(lfd))
    
    if isValid {
      reuseAddress = true
      if !bind(address) {
        close()
        return nil
      }
    }
  }
  
  /* proper close */
  
  override open func close() {
    if listenSource != nil {
      listenSource!.cancel()
      listenSource = nil
    }
    super.close()
  }
  
  /* start listening */
  
  open func listen(_ backlog: Int = 5) -> Bool {
    guard isValid      else { return false }
    guard !isListening else { return true }
    
    let rc = sysListen(fd.fd, Int32(backlog))
    guard rc == 0 else { return false }
    
    self.backlog       = backlog
    self.isNonBlocking = true
    return true
  }
  
  open func listen(_ queue: DispatchQueue, backlog: Int = 5,
                     accept: @escaping ( ActiveSocket<T> ) -> Void)
    -> Bool
  {
    guard fd.isValid   else { return false }
    guard !isListening else { return false }
    
    /* setup GCD dispatch source */

#if os(Linux) // is this GCD Linux vs GCD OSX or Swift 2.1 vs 2.2?
    let listenSource = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_READ,
      UInt(fd.fd), // is this going to bite us?
      0,
      queue
    )
#else // os(Darwin)
    guard let listenSource = DispatchSource.makeReadSource(fileDescriptor: fd.fd, queue: queue) /*Migrator FIXME: Use DispatchSourceRead to avoid the cast*/ as! DispatchSource
    else {
      return false
    }
#endif // os(Darwin)
    
    let lfd = fd.fd
    
    listenSource.onEvent { _, _ in
      repeat {
        // FIXME: tried to encapsulate this in a sockaddrbuf which does all
        //        the ptr handling, but it ain't work (autoreleasepool issue?)
        var baddr    = T()
        var baddrlen = socklen_t(baddr.len)
        
        let newFD = withUnsafeMutablePointer(to: &baddr) {
          ptr -> Int32 in
          let bptr = UnsafeMutablePointer<sockaddr>(ptr) // cast
          return sysAccept(lfd, bptr, &baddrlen);// buflenptr)
        }
        
        if newFD != -1 {
          // we pass over the queue, seems convenient. Not sure what kind of
          // queue setup a typical server would want to have
          let newSocket = ActiveSocket<T>(fd: FileDescriptor(newFD),
                                          remoteAddress: baddr, queue: queue)
          newSocket.isSigPipeDisabled = true // Note: not on Linux!
          
          accept(newSocket)
        }
        else if errno == EWOULDBLOCK {
          break
        }
        else { // great logging as Paul says
          print("Failed to accept() socket: \(self) \(errno)")
        }
        
      } while (true);
    }

    // cannot convert value of type 'dispatch_source_t' (aka 'COpaquePointer')
    // to expected argument type 'dispatch_object_t'
#if os(Linux)
    // TBD: what is the better way?
    dispatch_resume(unsafeBitCast(listenSource, dispatch_object_t.self))
#else /* os(Darwin) */
    listenSource.resume()
#endif /* os(Darwin) */
    
    guard listen(backlog) else {
      listenSource.cancel()
      return false
    }
    
    return true
  }
  
  
  /* description */
  
  override func descriptionAttributes() -> String {
    var s = super.descriptionAttributes()
    if isListening {
      s += " listening"
    }
    return s
  }
}