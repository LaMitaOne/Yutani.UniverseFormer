unit UniverseFormerSample;

{*******************************************************************************
  UniverseFormerSample Demo Wrapper
********************************************************************************
  A minimal threaded VCL Raylib wrapper designed to demonstrate the
  Yutani.Worlds.Space.UniverseFormer unit standalone.

  Includes SQLite-based Save/Load functionality so created universes
  can be persisted and reloaded. The SQLite bindings are inlined here
  to keep the sample standalone (no dependency on Yutani.Worlds.Space).
*******************************************************************************}

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.SyncObjs,
  Winapi.Windows, Winapi.MMSystem, Vcl.Controls, Raylib, rlgl, RayMath,
  Yutani.Worlds.Space.UniverseFormer;

const
  SPIN_THRESHOLD_NS = 2000000; // 2 ms threshold for spin-waiting

// --- Inlined SQLite Bindings ---
type
  TSQLiteDB = type Pointer;
  TSQLiteStmt = type Pointer;

const
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;
  SQLITE_OPEN_READWRITE = $00000002;
  SQLITE_OPEN_CREATE = $00000004;
  SQLITE_TRANSIENT = Pointer(-1);
  SQLITE_SQL_LENGTH_NULLTERM = -1;

function sqlite3_open_v2(filename: PAnsiChar; out db: TSQLiteDB; flags: Integer; vfs: PAnsiChar): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_close_v2(db: TSQLiteDB): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_prepare_v2(db: TSQLiteDB; sql: PAnsiChar; nByte: Integer; out stmt: TSQLiteStmt; tail: PPAnsiChar): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_step(stmt: TSQLiteStmt): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_reset(stmt: TSQLiteStmt): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_finalize(stmt: TSQLiteStmt): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_exec(db: TSQLiteDB; sql: PAnsiChar; callback: Pointer; arg: Pointer; errmsg: PPAnsiChar): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_free(p: Pointer): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_bind_int(stmt: TSQLiteStmt; idx: Integer; val: Integer): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_bind_int64(stmt: TSQLiteStmt; idx: Integer; val: Int64): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_bind_double(stmt: TSQLiteStmt; idx: Integer; val: Double): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_bind_text(stmt: TSQLiteStmt; idx: Integer; txt: PAnsiChar; nByte: Integer; destructor_: Pointer): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_bind_blob(stmt: TSQLiteStmt; idx: Integer; data: Pointer; nByte: Integer; destructor_: Pointer): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_bind_null(stmt: TSQLiteStmt; idx: Integer): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_column_int(stmt: TSQLiteStmt; idx: Integer): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_column_int64(stmt: TSQLiteStmt; idx: Integer): Int64; cdecl; external 'sqlite3.dll';
function sqlite3_column_double(stmt: TSQLiteStmt; idx: Integer): Double; cdecl; external 'sqlite3.dll';
function sqlite3_column_text(stmt: TSQLiteStmt; idx: Integer): PAnsiChar; cdecl; external 'sqlite3.dll';
function sqlite3_column_blob(stmt: TSQLiteStmt; idx: Integer): Pointer; cdecl; external 'sqlite3.dll';
function sqlite3_column_bytes(stmt: TSQLiteStmt; idx: Integer): Integer; cdecl; external 'sqlite3.dll';
function sqlite3_errmsg(db: TSQLiteDB): PAnsiChar; cdecl; external 'sqlite3.dll';

type
  THighResTimer = record
    Frequency: Int64;
    procedure Init;
    function GetTicks: Int64; inline;
    procedure HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
  end;

  TUniverseFormerSample = class(TThread)
  private
    FParentHandle: HWND;
    FRaylibWnd: HWND;
    FTargetFPS: Integer;
    FRealFPS: Integer;
    FActive: Boolean;
    FWidth, FHeight: Integer;
    FFormer: TUniverseFormer;
    FGLReady: Boolean;
    FPaused: Boolean;
    FSaveCallback: TUFNotifyEvent;
    FLoadCallback: TUFNotifyEvent;
    procedure RenderScene;
    procedure SetActive(const Value: Boolean);
    procedure UpdateState(const DeltaSec: Double);
    function GetHUDCallback(Index: Integer): TUFNotifyEvent;
    procedure SetHUDCallback(Index: Integer; const Value: TUFNotifyEvent);
  protected
    procedure Execute; override;
  public
    constructor Create(AParentHandle: HWND);
    destructor Destroy; override;

    procedure StartEngine;
    procedure StopEngine;
    procedure SetFPS(const FPS: Integer);
    procedure SetDimensions(const W, H: Integer);

    procedure TriggerSolSystem;
    procedure TriggerRandomSystem;
    procedure TriggerRandomUniverse;
    procedure TriggerClearAll;
    procedure SetPaused(const Value: Boolean);

    // --- Save/Load ---
    // Saves/Loads the universe to a SQLite DB file. Safe to call from
    // the VCL thread - uses its own DB connection.
    procedure SaveToFile(const FileName: string);
    procedure LoadFromFile(const FileName: string);

    function LiveObjectCount: Integer;

    // Pass-through HUD callbacks. The form subscribes to these to
    // open its TOpenDialog / TSaveDialog when the user clicks Save
    // or Load in the in-Raylib toolbar. The wrapper forwards them
    // straight to the underlying TUniverseFormer.
    property OnSaveRequested: TUFNotifyEvent index 0 read GetHUDCallback write SetHUDCallback;
    property OnLoadRequested: TUFNotifyEvent index 1 read GetHUDCallback write SetHUDCallback;

    property RealFPS: Integer read FRealFPS;
    property TargetFPS: Integer read FTargetFPS;
    property Active: Boolean read FActive write SetActive;
    property Paused: Boolean read FPaused write SetPaused;
  end;

implementation

{ THighResTimer }

procedure THighResTimer.Init;
begin
  if not QueryPerformanceFrequency(Frequency) then
    Frequency := 0;
end;

function THighResTimer.GetTicks: Int64;
begin
  QueryPerformanceCounter(Result);
end;

procedure THighResTimer.HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
var
  SpinTicks, Remaining: Int64;
begin
  if Frequency = 0 then Exit;
  SpinTicks := (ASpinNanoseconds * Frequency) div 1000000000;
  Remaining := ATargetTicks - GetTicks;
  while Remaining > SpinTicks do
  begin
    Sleep(1);
    Remaining := ATargetTicks - GetTicks;
  end;
  while GetTicks < ATargetTicks do ;
end;

{ TUniverseFormerSample }

constructor TUniverseFormerSample.Create(AParentHandle: HWND);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FParentHandle := AParentHandle;
  FTargetFPS := 60;
  FActive := False;
  FWidth := 1280;
  FHeight := 720;
  FPaused := False;
  FFormer := nil;
  FGLReady := False;
end;

destructor TUniverseFormerSample.Destroy;
begin
  StopEngine;
  FreeAndNil(FFormer);
  inherited;
end;

procedure TUniverseFormerSample.SetDimensions(const W, H: Integer);
begin
  if W < 64 then FWidth := 64 else FWidth := W;
  if H < 64 then FHeight := 64 else FHeight := H;
  if FRaylibWnd <> 0 then
  begin
    SetWindowPos(FRaylibWnd, 0, 0, 0, FWidth, FHeight, SWP_NOZORDER or SWP_NOACTIVATE);
    SetWindowSize(FWidth, FHeight);
  end;
end;

procedure TUniverseFormerSample.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    if FActive and Suspended then Start;
  end;
end;

procedure TUniverseFormerSample.StartEngine;
begin
  Active := True;
end;

procedure TUniverseFormerSample.StopEngine;
begin
  Active := False;
end;

procedure TUniverseFormerSample.SetFPS(const FPS: Integer);
begin
  if FTargetFPS <> FPS then FTargetFPS := FPS;
end;

procedure TUniverseFormerSample.UpdateState(const DeltaSec: Double);
var
  Dt: Single;
  MousePos: TVector2;
  ScreenW, ScreenH: Integer;
begin
  if not FGLReady then Exit;
  if (DeltaSec <= 0) or (DeltaSec > 0.25) then Dt := 1 / 60 else Dt := DeltaSec;

  MousePos := GetMousePosition();
  ScreenW := GetScreenWidth();
  ScreenH := GetScreenHeight();
  FFormer.Paused := FPaused;
  FFormer.Update(Dt, MousePos, ScreenW, ScreenH);
end;

procedure TUniverseFormerSample.TriggerSolSystem;
begin
  if FGLReady and Assigned(FFormer) then FFormer.SpawnSolSystemAtCamera;
end;

procedure TUniverseFormerSample.TriggerRandomSystem;
begin
  if FGLReady and Assigned(FFormer) then FFormer.SpawnRandomSystemAtCamera;
end;

procedure TUniverseFormerSample.TriggerRandomUniverse;
begin
  if FGLReady and Assigned(FFormer) then FFormer.SpawnRandomUniverseAtCamera;
end;

procedure TUniverseFormerSample.TriggerClearAll;
begin
  if FGLReady and Assigned(FFormer) then FFormer.ClearAll;
end;

procedure TUniverseFormerSample.SetPaused(const Value: Boolean);
begin
  FPaused := Value;
end;

function TUniverseFormerSample.LiveObjectCount: Integer;
begin
  if FGLReady and Assigned(FFormer) then Result := FFormer.LiveObjectCount else Result := 0;
end;

function TUniverseFormerSample.GetHUDCallback(Index: Integer): TUFNotifyEvent;
begin
  // Index 0 = Save, Index 1 = Load (matches the property declarations).
  if Index = 0 then
    Result := FSaveCallback
  else
    Result := FLoadCallback;
end;

procedure TUniverseFormerSample.SetHUDCallback(Index: Integer; const Value: TUFNotifyEvent);
begin
  // Cache locally AND forward to the underlying engine. The engine
  // only exists after the worker thread has spun up (Execute creates
  // it), so we guard the forward pass with FGLReady. If the form
  // subscribes BEFORE the engine is created (the usual case during
  // FormCreate), we still have the local copy and the Execute loop
  // will pick it up via SubscribeCallbacksToEngine when FFormer is
  // finally constructed.
  if Index = 0 then
    FSaveCallback := Value
  else
    FLoadCallback := Value;

  if FGLReady and Assigned(FFormer) then
  begin
    if Index = 0 then
      FFormer.OnSaveRequested := Value
    else
      FFormer.OnLoadRequested := Value;
  end;
end;

// ============================================================================
// SQLite Save/Load
// ============================================================================
// Schema (v1 - serialized November 2026 by LamitaOne):
//
//   CREATE TABLE meta (
//     key   TEXT PRIMARY KEY,
//     value TEXT
//   );
//   -- meta rows: 'schema_version' = '1', 'app_version' = 'v0.4'
//
//   CREATE TABLE systems (
//     id          INTEGER PRIMARY KEY,
//     pos_x       REAL, pos_y REAL, pos_z REAL,
//     tgt_x       REAL, tgt_y REAL, tgt_z REAL,
//     sun_r       REAL,
//     sun_cr      INTEGER, sun_cg INTEGER, sun_cb INTEGER,
//     is_binary   INTEGER,
//     sun2_r      REAL,
//     sun2_cr     INTEGER, sun2_cg INTEGER, sun2_cb INTEGER,
//     sun2_off    REAL,
//     bin_angle   REAL, bin_speed REAL,
//     bounds_r    REAL,
//     kind        INTEGER,
//     name        TEXT,
//     planets_blob BLOB
//   );
//
// planets_blob layout (binary, little-endian on x86/x64):
//   Offset 0..3   : Magic 'UFPL' ($55 $46 $50 $4C)
//   Offset 4..7   : Version (Int32)  = 1
//   Offset 8..11  : PlanetCount (Int32)
//   Offset 12..15 : FreePlanetCount (Int32)
//   Offset 16..   : Planets[PlanetCount]   as raw TUFPlanet records
//                    FreePlanets[FreeCnt]   as raw TUFPlanet records
//
// TUFPlanet is a plain-old-data record (no managed types), so a raw
// Move is safe. SizeOf(TUFPlanet) on Win64 is currently 48 bytes
// (4+4+4+4+4+4+4+1+3pad+12). Adding fields at the end is safe; bump
// the version if any field is removed/reordered.

const
  UF_BLOB_VERSION = 1;
  UF_BLOB_HEADER_SIZE = 16; // 4 magic + 4 ver + 4 cnt + 4 freecnt

type
  // Named type so the const and the header field share the same
  // type identity. Without this, Delphi refuses to assign one
  // anonymous array[0..3] of AnsiChar to another (E2008), even
  // though they have identical shape.
  TUFMagic = array[0..3] of AnsiChar;

  TUFBlobHeader = packed record
    Magic: TUFMagic;
    Version: Integer;
    PlanetCount: Integer;
    FreePlanetCount: Integer;
  end;

const
  UF_BLOB_MAGIC: TUFMagic = ('U','F','P','L');

procedure ExecSimpleSQL(DB: TSQLiteDB; const SQL: AnsiString);
var
  ErrMsg: PAnsiChar;
begin
  ErrMsg := nil;
  sqlite3_exec(DB, PAnsiChar(SQL), nil, nil, @ErrMsg);
  if ErrMsg <> nil then
  begin
    // Don't raise - just swallow. Save/Load failures are non-fatal.
    // The caller will see empty/missing data and abort gracefully.
    sqlite3_free(ErrMsg);
  end;
end;

// Builds a planets_blob in a temporary AnsiString and returns it.
// AnsiString is binary-safe in Delphi (uses counted length, not null
// terminators), so we can stuff any bytes inside.
function BuildPlanetsBlob(const S: TUFSystem): AnsiString;
var
  Hdr: TUFBlobHeader;
  PlanetBytes, FreeBytes, Total: NativeInt;
begin
  PlanetBytes := Length(S.Planets) * SizeOf(TUFPlanet);
  FreeBytes := Length(S.FreePlanets) * SizeOf(TUFPlanet);
  Total := UF_BLOB_HEADER_SIZE + PlanetBytes + FreeBytes;
  SetLength(Result, Total);

  Hdr.Magic := UF_BLOB_MAGIC;
  Hdr.Version := UF_BLOB_VERSION;
  Hdr.PlanetCount := Length(S.Planets);
  Hdr.FreePlanetCount := Length(S.FreePlanets);
  Move(Hdr, Result[1], UF_BLOB_HEADER_SIZE);

  if PlanetBytes > 0 then
    Move(S.Planets[0], Result[1 + UF_BLOB_HEADER_SIZE], PlanetBytes);
  if FreeBytes > 0 then
    Move(S.FreePlanets[0], Result[1 + UF_BLOB_HEADER_SIZE + PlanetBytes], FreeBytes);
end;

// Parses a planets_blob (from a SQLite BLOB column) and writes the
// planets back into the system record. Silently returns an empty
// system if the blob is missing/invalid.
procedure ParsePlanetsBlob(const Blob: Pointer; BlobBytes: Integer; out S: TUFSystem);
var
  Hdr: TUFBlobHeader;
  PlanetBytes, FreeBytes: NativeInt;
  PlanetCount, FreeCount: Integer;
begin
  S.Planets := nil;
  S.FreePlanets := nil;

  if (Blob = nil) or (BlobBytes < UF_BLOB_HEADER_SIZE) then Exit;
  Move(Blob^, Hdr, UF_BLOB_HEADER_SIZE);

  if Hdr.Magic <> UF_BLOB_MAGIC then Exit;
  if Hdr.Version <> UF_BLOB_VERSION then Exit;

  PlanetCount := Hdr.PlanetCount;
  FreeCount := Hdr.FreePlanetCount;
  if (PlanetCount < 0) or (PlanetCount > 1024) then Exit;
  if (FreeCount < 0) or (FreeCount > 1024) then Exit;

  PlanetBytes := PlanetCount * SizeOf(TUFPlanet);
  FreeBytes := FreeCount * SizeOf(TUFPlanet);
  if BlobBytes < UF_BLOB_HEADER_SIZE + PlanetBytes + FreeBytes then Exit;

  if PlanetCount > 0 then
  begin
    SetLength(S.Planets, PlanetCount);
    Move((PByte(Blob) + UF_BLOB_HEADER_SIZE)^, S.Planets[0], PlanetBytes);
  end;
  if FreeCount > 0 then
  begin
    SetLength(S.FreePlanets, FreeCount);
    Move((PByte(Blob) + UF_BLOB_HEADER_SIZE + PlanetBytes)^, S.FreePlanets[0], FreeBytes);
  end;
end;

// We must declare sqlite3_free because we use it in ExecSimpleSQL.
// (Declared in the interface section alongside the other imports.)

procedure TUniverseFormerSample.SaveToFile(const FileName: string);
var
  DB: TSQLiteDB;
  Stmt: TSQLiteStmt;
  SQL: AnsiString;
  I, Res, SavedCount: Integer;
  S: TUFSystem;
  Blob: AnsiString;
  ANsiName: AnsiString;
begin
  if not (FGLReady and Assigned(FFormer)) then Exit;

  if sqlite3_open_v2(PAnsiChar(AnsiString(FileName)), DB,
    SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil) <> SQLITE_OK then
    Exit;
  try
    // Drop old tables and create fresh ones. This avoids schema drift
    // across versions and is cheap on a fresh file.
    ExecSimpleSQL(DB, 'DROP TABLE IF EXISTS systems;');
    ExecSimpleSQL(DB, 'DROP TABLE IF EXISTS meta;');
    ExecSimpleSQL(DB,
      'CREATE TABLE systems (' +
      '  id INTEGER PRIMARY KEY,' +
      '  pos_x REAL, pos_y REAL, pos_z REAL,' +
      '  tgt_x REAL, tgt_y REAL, tgt_z REAL,' +
      '  sun_r REAL,' +
      '  sun_cr INTEGER, sun_cg INTEGER, sun_cb INTEGER,' +
      '  is_binary INTEGER,' +
      '  sun2_r REAL,' +
      '  sun2_cr INTEGER, sun2_cg INTEGER, sun2_cb INTEGER,' +
      '  sun2_off REAL,' +
      '  bin_angle REAL, bin_speed REAL,' +
      '  bounds_r REAL,' +
      '  kind INTEGER,' +
      '  name TEXT,' +
      '  planets_blob BLOB' +
      ');');
    ExecSimpleSQL(DB,
      'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);');
    ExecSimpleSQL(DB,
      'INSERT INTO meta (key, value) VALUES (''schema_version'', ''1'');');
    ExecSimpleSQL(DB,
      'INSERT INTO meta (key, value) VALUES (''app_version'', ''v0.4'');');

    // BEGIN TRANSACTION - this is the single most important line for
    // performance. Without it, SQLite wraps every INSERT in its own
    // transaction, fsync-ing the journal after each one. Saving 8000
    // systems without a transaction takes minutes; with one, <1s.
    ExecSimpleSQL(DB, 'BEGIN TRANSACTION;');

    SQL :=
      'INSERT INTO systems (' +
      '  pos_x, pos_y, pos_z, tgt_x, tgt_y, tgt_z,' +
      '  sun_r, sun_cr, sun_cg, sun_cb,' +
      '  is_binary, sun2_r, sun2_cr, sun2_cg, sun2_cb, sun2_off,' +
      '  bin_angle, bin_speed, bounds_r, kind, name, planets_blob' +
      ') VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);';

    if sqlite3_prepare_v2(DB, PAnsiChar(SQL), SQLITE_SQL_LENGTH_NULLTERM, Stmt, nil) <> SQLITE_OK then
      Exit;
    try
      SavedCount := 0;
      // Iterate the WHOLE allocated array, not LiveSystemCount.
      // LiveSystemCount is a count of alive systems; if we used it as
      // a loop bound we'd skip alive systems that sit past dead ones
      // in the array. Iterating GetSystemCount (= FSystemCount) and
      // checking IsDead is the only correct way.
      for I := 0 to FFormer.GetSystemCount - 1 do
      begin
        S := FFormer.GetSystemData(I);
        if S.IsDead then Continue;

        sqlite3_bind_double(Stmt, 1,  S.Position.x);
        sqlite3_bind_double(Stmt, 2,  S.Position.y);
        sqlite3_bind_double(Stmt, 3,  S.Position.z);
        sqlite3_bind_double(Stmt, 4,  S.TargetPosition.x);
        sqlite3_bind_double(Stmt, 5,  S.TargetPosition.y);
        sqlite3_bind_double(Stmt, 6,  S.TargetPosition.z);
        sqlite3_bind_double(Stmt, 7,  S.SunRadius);
        sqlite3_bind_int   (Stmt, 8,  S.SunColor.r);
        sqlite3_bind_int   (Stmt, 9,  S.SunColor.g);
        sqlite3_bind_int   (Stmt, 10, S.SunColor.b);
        sqlite3_bind_int   (Stmt, 11, Ord(S.IsBinary));
        sqlite3_bind_double(Stmt, 12, S.Sun2Radius);
        sqlite3_bind_int   (Stmt, 13, S.Sun2Color.r);
        sqlite3_bind_int   (Stmt, 14, S.Sun2Color.g);
        sqlite3_bind_int   (Stmt, 15, S.Sun2Color.b);
        sqlite3_bind_double(Stmt, 16, S.Sun2Offset);
        sqlite3_bind_double(Stmt, 17, S.BinaryAngle);
        sqlite3_bind_double(Stmt, 18, S.BinarySpeed);
        sqlite3_bind_double(Stmt, 19, S.BoundsRadius);
        sqlite3_bind_int   (Stmt, 20, Ord(S.Kind));

        ANsiName := S.Name;
        if ANsiName <> '' then
          sqlite3_bind_text(Stmt, 21, PAnsiChar(ANsiName), Length(ANsiName), SQLITE_TRANSIENT)
        else
          sqlite3_bind_null(Stmt, 21);

        Blob := BuildPlanetsBlob(S);
        if Length(Blob) > 0 then
          sqlite3_bind_blob(Stmt, 22, PAnsiChar(Blob), Length(Blob), SQLITE_TRANSIENT)
        else
          sqlite3_bind_null(Stmt, 22);

        Res := sqlite3_step(Stmt);
        if Res = SQLITE_DONE then
          Inc(SavedCount);

        // Reset for the next iteration - much cheaper than
        // finalize+re-prepare (which the original code did).
        sqlite3_reset(Stmt);
      end;
    finally
      sqlite3_finalize(Stmt);
    end;

    ExecSimpleSQL(DB, 'COMMIT;');
  finally
    sqlite3_close_v2(DB);
  end;
end;

procedure TUniverseFormerSample.LoadFromFile(const FileName: string);
var
  DB: TSQLiteDB;
  Stmt: TSQLiteStmt;
  SQL: AnsiString;
  Res: Integer;
  S: TUFSystem;
  I: Integer;
  NamePtr: PAnsiChar;
  BlobPtr: Pointer;
  BlobBytes: Integer;
begin
  if not (FGLReady and Assigned(FFormer)) then Exit;
  // Qualify with SysUtils. because Raylib also exports a
  // FileExists(PAnsiChar); without qualification the Raylib overload
  // wins (Raylib is listed after SysUtils in the uses clause) and
  // passing a `string` to it is an incompatible-types error.
  if not System.SysUtils.FileExists(FileName) then Exit;

  // SQLITE_OPEN_READONLY would suffice, but using READWRITE allows
  // SQLite to create the -wal/-shm sidecars if needed. Falls back
  // gracefully if the file is read-only.
  if sqlite3_open_v2(PAnsiChar(AnsiString(FileName)), DB, SQLITE_OPEN_READWRITE, nil) <> SQLITE_OK then
  begin
    if sqlite3_open_v2(PAnsiChar(AnsiString(FileName)), DB, 1 {SQLITE_OPEN_READONLY}, nil) <> SQLITE_OK then
      Exit;
  end;
  try
    // Wipe the in-memory state. ClearAllSystems sets IsDead=True on
    // slots 0..FSystemCount-1 and zeroes their Planets arrays. Then
    // SetSystemCount(0) makes the renderer skip them entirely.
    FFormer.ClearAllSystems;
    FFormer.SetSystemCount(0);

    // Read systems table. Note: planets_blob IS selected - the original
    // code forgot to load it, which silently dropped every planet on
    // reload.
    SQL :=
      'SELECT pos_x, pos_y, pos_z, tgt_x, tgt_y, tgt_z,' +
      '  sun_r, sun_cr, sun_cg, sun_cb,' +
      '  is_binary, sun2_r, sun2_cr, sun2_cg, sun2_cb, sun2_off,' +
      '  bin_angle, bin_speed, bounds_r, kind, name, planets_blob ' +
      'FROM systems ORDER BY id;';

    if sqlite3_prepare_v2(DB, PAnsiChar(SQL), SQLITE_SQL_LENGTH_NULLTERM, Stmt, nil) <> SQLITE_OK then
      Exit;

    I := 0;
    Res := sqlite3_step(Stmt);
    while (Res = SQLITE_ROW) and (I < FFormer.GetMaxSystems) do
    begin
      S := Default(TUFSystem);
      S.Position.x := sqlite3_column_double(Stmt, 0);
      S.Position.y := sqlite3_column_double(Stmt, 1);
      S.Position.z := sqlite3_column_double(Stmt, 2);
      S.TargetPosition.x := sqlite3_column_double(Stmt, 3);
      S.TargetPosition.y := sqlite3_column_double(Stmt, 4);
      S.TargetPosition.z := sqlite3_column_double(Stmt, 5);
      S.SunRadius := sqlite3_column_double(Stmt, 6);
      S.SunColor.r := sqlite3_column_int(Stmt, 7);
      S.SunColor.g := sqlite3_column_int(Stmt, 8);
      S.SunColor.b := sqlite3_column_int(Stmt, 9);
      S.SunColor.a := 255;
      S.IsBinary := Boolean(sqlite3_column_int(Stmt, 10));
      S.Sun2Radius := sqlite3_column_double(Stmt, 11);
      S.Sun2Color.r := sqlite3_column_int(Stmt, 12);
      S.Sun2Color.g := sqlite3_column_int(Stmt, 13);
      S.Sun2Color.b := sqlite3_column_int(Stmt, 14);
      S.Sun2Color.a := 255;
      S.Sun2Offset := sqlite3_column_double(Stmt, 15);
      S.BinaryAngle := sqlite3_column_double(Stmt, 16);
      S.BinarySpeed := sqlite3_column_double(Stmt, 17);
      S.BoundsRadius := sqlite3_column_double(Stmt, 18);
      S.Kind := TUFSystemKind(sqlite3_column_int(Stmt, 19));

      NamePtr := sqlite3_column_text(Stmt, 20);
      if NamePtr <> nil then
        S.Name := AnsiString(NamePtr)
      else
        S.Name := '';

      S.IsDead := False;

      // Restore the planets arrays from the blob. ParsePlanetsBlob
      // writes directly into S.Planets and S.FreePlanets.
      BlobPtr := sqlite3_column_blob(Stmt, 21);
      BlobBytes := sqlite3_column_bytes(Stmt, 21);
      ParsePlanetsBlob(BlobPtr, BlobBytes, S);

      // SetSystemData writes the record AND syncs TargetPosition to
      // Position (in case the loaded target differs - we keep both
      // because the saved state may have been mid-animation).
      FFormer.SetSystemData(I, S);
      // Re-apply the loaded TargetPosition, since SetSystemData may
      // have overwritten it with Position.
      FFormer.SetSystemTargetPosition(I, S.TargetPosition);
      Inc(I);

      Res := sqlite3_step(Stmt);
    end;
    sqlite3_finalize(Stmt);
    FFormer.SetSystemCount(I);
  finally
    sqlite3_close_v2(DB);
  end;
end;

// ============================================================================
// Render & Main Loop
// ============================================================================

procedure TUniverseFormerSample.RenderScene;
begin
  BeginDrawing();
  ClearBackground(BLACK);
  if FGLReady and Assigned(FFormer) then FFormer.Render
  else DrawText('Initializing universe former...', 10, 10, 20, YELLOW);
  // No FPS overlay here - the engine's own status bar already shows
  // FPS in the bottom-left, so a second green number on top would be
  // redundant and overlap the toolbar text.
  EndDrawing();

  if FRaylibWnd <> 0 then
    RedrawWindow(FRaylibWnd, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);
end;

procedure TUniverseFormerSample.Execute;
var
  Timer: THighResTimer;
  Freq, FrameTicks: Int64;
  NextFrame, NowTicks, LastFrameTicks: Int64;
  DeltaSec: Double;
  FrameCount: Integer;
  LastFpsTime: Int64;
  WindowName: AnsiString;
begin
  {$IFDEF MSWINDOWS}
  timeBeginPeriod(1);
  {$ENDIF}
  try
    SetConfigFlags(FLAG_MSAA_4X_HINT or FLAG_WINDOW_ALWAYS_RUN);
    WindowName := AnsiString('UniverseFormerSample_' + IntToStr(IntPtr(Self)));
    InitWindow(FWidth, FHeight, PAnsiChar(WindowName));

    // CRITICAL: disable Raylib's default ESC-to-close behavior. By
    // default, pressing ESC makes WindowShouldClose() return true,
    // which would break our main loop and destroy the GL context.
    // In an embedded child window that manifests as the entire
    // viewport turning white - no error in the debugger, just a
    // frozen white panel. The engine handles ESC itself in Update
    // (deselects system + disarms brush).
    SetExitKey(0);

    FRaylibWnd := FindWindowA(nil, PAnsiChar(WindowName));
    if (FRaylibWnd <> 0) and (FParentHandle <> 0) then
    begin
      Winapi.Windows.SetParent(FRaylibWnd, FParentHandle);
      SetWindowLong(FRaylibWnd, GWL_STYLE, WS_CHILD or WS_VISIBLE);
      SetWindowPos(FRaylibWnd, 0, 0, 0, FWidth, FHeight, SWP_NOZORDER or SWP_NOACTIVATE);
    end;

    FFormer := TUniverseFormer.Create(Default(TShader));
    FGLReady := True;

    // Forward any HUD callbacks that the form subscribed BEFORE the
    // engine existed. Without this, callbacks set in FormCreate
    // (the typical case) would never reach the engine and clicks on
    // the in-Raylib Save/Load buttons would silently do nothing.
    FFormer.OnSaveRequested := FSaveCallback;
    FFormer.OnLoadRequested := FLoadCallback;

    Timer.Init;
    Freq := Timer.Frequency;
    if Freq <= 0 then Freq := 10000000;

    NowTicks := Timer.GetTicks;
    LastFrameTicks := NowTicks;
    NextFrame := NowTicks;
    LastFpsTime := NowTicks;
    FrameCount := 0;

    while not Terminated do
    begin
      if WindowShouldClose() then Break;
      NowTicks := Timer.GetTicks;
      DeltaSec := (NowTicks - LastFrameTicks) / Freq;
      LastFrameTicks := NowTicks;
      if (DeltaSec <= 0) or (DeltaSec > 0.25) then DeltaSec := 1 / 60;

      if FActive then UpdateState(DeltaSec);
      RenderScene;

      Inc(FrameCount);
      if (NowTicks - LastFpsTime) >= Freq then
      begin
        FRealFPS := Round(FrameCount * Freq / (NowTicks - LastFpsTime));
        FrameCount := 0;
        LastFpsTime := NowTicks;
      end;

      if FTargetFPS > 0 then FrameTicks := Round(Freq / FTargetFPS)
      else FrameTicks := Freq div 60;
      NextFrame := NextFrame + FrameTicks;
      NowTicks := Timer.GetTicks;
      if (NowTicks - NextFrame) > Freq then NextFrame := NowTicks;
      Timer.HybridWaitUntil(NextFrame, SPIN_THRESHOLD_NS);
    end;
  finally
    FreeAndNil(FFormer);
    FGLReady := False;
    if FRaylibWnd <> 0 then CloseWindow();
    {$IFDEF MSWINDOWS}
    timeEndPeriod(1);
    {$ENDIF}
  end;
end;

end.

