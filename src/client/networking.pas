unit networking;

{$mode objfpc}{$H+}

interface

uses
  {$ifdef unix}errors,{$endif}
  Classes, SysUtils, Sockets, resolve;

const
  Sys_EINPROGRESS = 115;
  Sys_EAGAIN = 11;
{$ifdef windows}
  SND_FLAGS = 0;
  RCV_FLAGS = 0;
{$else}
  SOCKET_ERROR = -1;
  SND_FLAGS = MSG_NOSIGNAL;
  RCV_FLAGS = MSG_NOSIGNAL;
{$endif}

type
  ENetworkError = class(Exception)
  end;

  { TConnection wraps a socket}
  TConnection = class(THandleStream)
    constructor Create(AHandle: THandle); virtual;
    destructor Destroy; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    procedure WriteLn(S: String); virtual;
    procedure DoClose; virtual;
  strict protected
    FClosed: Boolean;
    procedure SetClosed; virtual;
  public
    property Closed: Boolean read FClosed;
  end;

  TConnectionClass = class of TConnection;
  TListenerCallback = procedure(AConnection: TConnection) of object;

  { TListener }
  TListener = class(TThread)
    constructor Create(APort: DWord; ACallback: TListenerCallback); reintroduce;
    procedure Execute; override;
    procedure Terminate;
  strict protected
    FPort     : DWord;
    FSocket   : THandle;
    FCallback : TListenerCallback;
  end;

var
  // the class of connection to automatically instantiate.
  // defaults to TConnection but at runtime we will change this.
  ConnectionClass : TConnectionClass = TConnection;

  // which ID to send to the socks proxy
  SOCKS_USER_ID : String = '';

function ConnectTCP(AServer: String; APort: DWord): TConnection;
function ConnectSocks4a(AProxy: String; AProxyPort: DWord; AServer: String; APort: DWord): TConnection;
function NameResolve(AName: String): THostAddr;

implementation

function SockLastErrStr: String;
begin
  {$ifdef unix}
  Result := StrError(SocketError);
  {$else}
  {$note find the winndows version of the above}
  Result := IntToStr(SocketError);
  {$endif}
end;

function CreateSocketHandle: THandle;
begin
  Result := Sockets.FPSocket(AF_INET, SOCK_STREAM, 0);
  if Result <= 0 then
    raise ENetworkError.CreateFmt('could not create socket (%s)',
      [SockLastErrStr]);
end;

procedure CloseSocketHandle(ASocket: THandle);
begin
  fpshutdown(ASocket, SHUT_RDWR);
  Sockets.CloseSocket(ASocket);
end;

procedure ConnectSocketHandle(ASocket: THandle; AServer: String; APort: DWord);
var
  HostAddr: THostAddr;     // host byte order
  SockAddr: TInetSockAddr; // network byte order
  HSocket: THandle;
begin
  HostAddr := NameResolve(AServer);
  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := ShortHostToNet(APort);
  SockAddr.sin_addr := HostToNet(HostAddr);
  if Sockets.FpConnect(ASocket, @SockAddr, SizeOf(SockAddr))<>0 Then
    if (SocketError <> Sys_EINPROGRESS) and (SocketError <> 0) then
      raise ENetworkError.CreateFmt('connect failed: %s:%d (%s)',
        [AServer, APort, SockLastErrStr]);
end;

{ TListener }

constructor TListener.Create(APort: DWord; ACallback: TListenerCallback);
begin
  FPort := APort;
  FCallback := ACallback;
  Inherited Create(false);
end;

procedure TListener.Execute;
var
  TrueValue : Integer;
  SockAddr  : TInetSockAddr;
  SockAddrx : TInetSockAddr;
  AddrLen   : PtrInt;
  Incoming  : THandle;
begin
  TrueValue := 1;
  AddrLen := SizeOf(SockAddr);

  FSocket := CreateSocketHandle;
  fpSetSockOpt(FSocket, SOL_SOCKET, SO_REUSEADDR, @TrueValue, SizeOf(TrueValue));
  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := ShortHostToNet(FPort);
  SockAddr.sin_addr.s_addr := 0;

  if fpBind(FSocket, @SockAddr, SizeOf(SockAddr))<>0 then
    raise ENetworkError.CreateFmt('could not bind port %d (%s)',
      [FPort, SockLastErrStr]);

  fpListen(FSocket, 1);
  repeat
    Incoming := fpaccept(FSocket, @SockAddrx, @AddrLen);
    if Incoming > 0 then
      FCallback(ConnectionClass.Create(Incoming))
    else
      break;
  until Terminated;
end;

procedure TListener.Terminate;
begin
  CloseSocketHandle(Self.FSocket);
  inherited Terminate;
end;

{ TConnection }

constructor TConnection.Create(AHandle: THandle);
begin
  inherited Create(AHandle);
end;

destructor TConnection.Destroy;
begin
  DoClose;
  inherited Destroy;
end;

function TConnection.Write(const Buffer; Count: LongInt): LongInt;
begin
  Result := fpSend(Handle, @Buffer, Count, SND_FLAGS);
end;

function TConnection.Read(var Buffer; Count: LongInt): LongInt;
begin
  Result := fpRecv(Handle, @Buffer, Count, RCV_FLAGS);
  if Result = SOCKET_ERROR then
    DoClose;
end;

procedure TConnection.WriteLn(S: String);
var
  Buf: String;
begin
  Buf := S + #10; // LF is the TorChat message delimiter (on all platforms!)
  self.Write(Buf[1], Length(Buf));
end;

procedure TConnection.DoClose;
begin
  if not Closed then begin
    CloseSocketHandle(Handle);
    SetClosed;
  end;
end;

procedure TConnection.SetClosed;
begin
  FClosed := True;
end;


function ConnectTCP(AServer: String; APort: DWord): TConnection;
var
  HSocket: THandle;
begin
  HSocket := CreateSocketHandle;
  ConnectSocketHandle(HSocket, AServer, APort);
  Result := ConnectionClass.Create(HSocket);
end;

function ConnectSocks4a(AProxy: String; AProxyPort: DWord; AServer: String; APort: DWord): TConnection;
var
  HSocket: THandle;
  REQ : String;
  ANS : array[1..8] of Byte;
begin
  HSocket := CreateSocketHandle;
  ConnectSocketHandle(HSocket, AProxy, AProxyPort);
  SetLength(REQ, 8);
  REQ[1] := #4; // Socks 4
  REQ[2] := #1; // CONNECT command
  PWord(@REQ[3])^ := ShortHostToNet(APort);
  PDWord(@REQ[5])^ := HostToNet(1); // address '0.0.0.1' means: Socks 4a
  REQ := REQ + SOCKS_USER_ID + #0;
  REQ := REQ + AServer + #0;
  fpSend(HSocket, @REQ[1], Length(REQ), SND_FLAGS);
  ANS[1] := $ff;
  if (fpRecv(HSocket, @ANS, 8, RCV_FLAGS) = 8) and (ANS[1] = 0) then begin
    if ANS[2] = 90 then begin
      Result := ConnectionClass.Create(HSocket);
    end
    else begin
      Raise ENetworkError.CreateFmt(
        'socks connect %s:%d via %s:%d failed (error %d)',
        [AServer, APort, AProxy, AProxyPort, ANS[2]]
      );
    end;
  end
  else begin
    Raise ENetworkError.CreateFmt(
      'socks connect %s:%d via %s:%d handshake invalid response',
      [AServer, APort, AProxy, AProxyPort]
    );
  end;
end;

function NameResolve(AName: String): THostAddr;
var
  Resolver: THostResolver;
begin
  Result := StrToHostAddr(AName);
  if Result.s_addr = 0 then begin
    try
      Resolver := THostResolver.Create(nil);
      if not Resolver.NameLookup(AName) then
        raise ENetworkError.CreateFmt('could not resolve address: %s', [AName]);
      Result := Resolver.HostAddress;
    finally
      Resolver.Free;
    end;
  end;
end;

end.

