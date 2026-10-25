unit Yutani.Worlds.Space.Visuals;

{==============================================================================*
 *  Yutani Space Visuals - Procedural Cosmic Backdrop Enhancements
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    Drop-in visual enhancement addon for Yutani.Worlds.Space. Provides:
 *
 *      - Multi-directional distant spiral galaxies (exponential disk +
 *        logarithmic spiral arms + Gaussian bulge + spectral color bias)
 *      - 6-point diffraction-spike star sprites (telescope-photo look)
 *      - 4-point star sprite (kept for compatibility / smaller stars)
 *      - Harvard spectral-classification star colors (O B A F G K M)
 *      - Dual-tail comet particle system (blue ion tail + warm curved
 *        dust tail driven by solar radiation pressure)
 *      - Optional sun corona shader (3-octave value noise plasma flow)
 *
 *  Integration:
 *    Drop this unit next to Yutani.Worlds.Space.pas and wire it up like so:
 *
 *      // In TSpaceWorld private section:
 *      FVisuals: TSpaceVisuals;
 *
 *      // In TSpaceWorld.Create, after InitializeDistantStars:
 *      FVisuals := TSpaceVisuals.Create;
 *      FVisuals.InitializeGalaxies(4, 6000);
 *
 *      // In TSpaceWorld.Update, after FTime := FTime + dt:
 *      FVisuals.Update(dt);
 *
 *      // In TSpaceWorld.Render, after RenderNearStars and before
 *      // RenderPlanets:
 *      FVisuals.RenderDistantGalaxies(FCameraPos, CamRight, CamUp);
 *
 *      // In TSpaceWorld.Destroy:
 *      FreeAndNil(FVisuals);
 *
 *    Optional: replace the existing comet particle stream with the dual-tail
 *    system by calling FVisuals.SpawnDualTail(...) from your comet update
 *    path and FVisuals.RenderDualTail(...) from your comet render path.
 *
 *    Optional: enable the sun corona by calling FVisuals.RenderSunCorona(...)
 *    from TSpaceWorld.RenderSuns after the solid sun core is drawn. The
 *    shader is lazy-initialized on first use.
 *
 *  Thread Safety:
 *    All public methods must be called from the Raylib render thread, same
 *    as the rest of TSpaceWorld. No locking is performed internally.
 *
 *  Memory Management:
 *    TSpaceVisuals owns all its arrays and the corona shader. Destroying
 *    the instance releases everything; no manual cleanup is required.
 *==============================================================================}

{$POINTERMATH ON}
{$Q-}
{$R-}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math,
  Raylib, RayMath, rlgl;

const
  // --- Distant galaxy tuning -------------------------------------------
  // Values are calibrated for a celestial-sphere backdrop at
  // DISTANT_SHELL_RADIUS (950.0). Tweak here to change the look without
  // touching the generation code.
  DEFAULT_GALAXY_COUNT         = 4;
  DEFAULT_GALAXY_STARS         = 6000;
  GALAXY_ANGULAR_RADIUS        = 0.05;   // ~2.9 degrees on the sky
  GALAXY_BULGE_RADIUS_FRAC     = 0.18;   // Bulge occupies inner 18% of disk
  GALAXY_DISK_SCALE_FRAC       = 0.28;   // Exponential disk scale length
  GALAXY_THICKNESS_FRAC        = 0.04;   // Vertical thickness (Gaussian sigma)
  GALAXY_ARM_TIGHTNESS         = 0.6;    // Logarithmic spiral pitch
  GALAXY_ARM_FRACTION          = 0.35;   // 35% of stars live in spiral arms

  // --- Star sprite tuning ----------------------------------------------
  STAR_SPIKE_LEN_MULT          = 2.0;    // Spike length as multiple of size

  // --- Dual-tail comet tuning ------------------------------------------
  DUAL_TAIL_MAX_PARTICLES      = 12000;
  DUAL_TAIL_ION_PRESSURE       = 2.0;    // Ion tail radiation pressure mult
  DUAL_TAIL_DUST_PRESSURE      = 0.6;    // Dust tail radiation pressure mult
  DUAL_TAIL_DUST_LAG           = 0.4;    // How much dust follows orbital vel
  DUAL_TAIL_ION_LAG            = 0.05;   // How much ion follows orbital vel
  DUAL_TAIL_ION_DRAG           = 0.4;    // Per-second velocity drag for ion
  DUAL_TAIL_DUST_DRAG          = 0.2;    // Per-second velocity drag for dust
  DUAL_TAIL_RADIATION_CONSTANT = 8000.0; // Pressure = K / dist^2 (tunable)

  // --- Distant shell radius (must match Yutani.Worlds.Space) -----------
  DISTANT_SHELL_RADIUS_VIS     = 950.0;

type
  /// <summary>
  /// Harvard spectral classification indices for GetStarColorStellar.
  /// 0 = O (hottest, blue) ... 6 = M (coolest, red-orange).
  /// </summary>
  TStellarClass = 0..6;

  /// <summary>
  /// One star inside a distant spiral galaxy backdrop. Lives on the
  /// celestial sphere at DISTANT_SHELL_RADIUS distance from the camera,
  /// so it never gets closer as the player flies through the universe.
  /// </summary>
  TDistantGalaxyStar = record
    Dir: TVector3;           // Direction from origin (unit vector)
    Brightness: Single;      // 0..1 brightness multiplier
    Size: Single;            // Sprite size in world units
    ColorTint: Byte;         // TStellarClass index
    TwinklePhase: Single;    // Random phase offset for twinkle
    TwinkleSpeed: Single;    // Twinkle frequency
  end;

  /// <summary>
  /// One distant spiral galaxy. Visible from anywhere because it lives
  /// on the celestial sphere - the player can never reach it.
  /// </summary>
  TDistantGalaxy = record
    CenterDir: TVector3;     // Center direction on celestial sphere
    AngularRadius: Single;   // Visual size on sky (radians)
    ArmCount: Integer;       // Number of spiral arms (1, 2 or 3)
    TintR, TintG, TintB: Byte; // Overall color tint (redshift etc.)
    Stars: TArray<TDistantGalaxyStar>;
  end;

  /// <summary>
  /// Tail kind discriminator for dual-tail comet particles.
  /// </summary>
  TTailKind = (tkIon, tkDust);

  /// <summary>
  /// One dual-tail comet particle. Ion particles are blue and straight;
  /// dust particles are warm yellow and curved. Both are pushed away
  /// from the nearest sun by radiation pressure.
  /// </summary>
  TDualTailParticle = record
    Position: TVector3;
    Velocity: TVector3;
    Life: Single;
    MaxLife: Single;
    Size: Single;
    TailKind: TTailKind;
    Active: Boolean;
  end;

  /// <summary>
  /// Visual enhancement addon for TSpaceWorld. Owns its own state for
  /// distant galaxies and dual-tail particles; provides pure helpers
  /// for star sprites and stellar colors. Lazy-initializes the sun
  /// corona shader on first use.
  /// </summary>
  TSpaceVisuals = class
  private
    FGalaxies: TArray<TDistantGalaxy>;
    FDualTailParticles: TArray<TDualTailParticle>;
    FDualTailCount: Integer;
    FTime: Single;
    FRngState: Cardinal;
    // Sun corona shader state (lazy-init on first RenderSunCorona call)
    FCoronaShader: TShader;
    FCoronaTimeLoc: Integer;
    FCoronaColorLoc: Integer;
    FCoronaInitialized: Boolean;

    // Internal RNG (xorshift32 - deterministic, no allocation)
    procedure SeedRand(Seed: Cardinal);
    function NextRand: Single;

    // Property getters (Delphi property readers must be fields or
    // parameterless methods - expressions like Length(FGalaxies) are
    // not legal in the read clause).
    function GetGalaxyCount: Integer;

    // Galaxy generator - builds one spiral galaxy on the celestial sphere
    procedure GenerateGalaxy(var Galaxy: TDistantGalaxy;
      const CenterDir: TVector3; AngularRadius: Single;
      StarCount: Integer; ArmCount: Integer; const Tint: TColorB);
  public
    constructor Create;
    destructor Destroy; override;

    // --- Lifecycle ------------------------------------------------------

    /// <summary>
    /// Initializes the distant spiral galaxy backdrops. Call once from
    /// TSpaceWorld.Create, after InitializeDistantStars. Galaxies are
    /// placed at fixed directions on the celestial sphere so they stay
    /// consistent across runs.
    /// </summary>
    procedure InitializeGalaxies(Count: Integer = DEFAULT_GALAXY_COUNT;
      StarsPerGalaxy: Integer = DEFAULT_GALAXY_STARS);

    /// <summary>
    /// Advances internal time (drives twinkle and corona flow). Call
    /// every frame from TSpaceWorld.Update.
    /// </summary>
    procedure Update(const dt: Single);

    // --- Distant galaxy rendering --------------------------------------

    /// <summary>
    /// Renders all distant spiral galaxies. Call after RenderDistantStars
    /// and before RenderPlanets so galaxies sit between background stars
    /// and foreground planets in the visual hierarchy. Uses additive
    /// blending with no depth writes so galaxies never occlude foreground
    /// objects.
    /// </summary>
    procedure RenderDistantGalaxies(const CameraPos, CamRight, CamUp: TVector3);

    // --- Star sprite helpers (pure) ------------------------------------

    /// <summary>
    /// 6-point diffraction-spike star sprite. Drop-in replacement for
    /// TSpaceWorld.DrawStarSprite with a more "telescope photograph"
    /// look. Use for bright foreground stars and galactic cores.
    /// </summary>
    procedure DrawStarSprite6(const Pos, CamRight, CamUp: TVector3;
      Size: Single; Col: TColorB; Alpha: Byte);

    /// <summary>
    /// 4-point star sprite - original Yutani style, kept for small /
    /// background stars where the 6-point version would be visually
    /// too busy.
    /// </summary>
    procedure DrawStarSprite4(const Pos, CamRight, CamUp: TVector3;
      Size: Single; Col: TColorB; Alpha: Byte);

    /// <summary>
    /// Harvard spectral colors. ClassIndex 0 = O (blue, hottest),
    /// ClassIndex 6 = M (red-orange, coolest). Drop-in replacement
    /// for TSpaceWorld.GetStarColor.
    /// </summary>
    function GetStarColorStellar(ClassIndex: Byte; Alpha: Byte): TColorB;

    // --- Dual-tail comet system ----------------------------------------

    /// <summary>
    /// Spawns ion + dust tail particles for one comet. Call from
    /// TSpaceWorld's comet update path (e.g. where SpawnCometParticle
    /// is currently called). NearestSunPos drives the radiation
    /// pressure: tails always point away from the sun.
    /// </summary>
    procedure SpawnDualTail(const CometPos, CometVel: TVector3;
      CometSize: Single; const NearestSunPos: TVector3;
      ParticlesPerCall: Integer = 6);

    /// <summary>
    /// Updates all dual-tail particles. Call every frame from
    /// TSpaceWorld.UpdateCometParticles (or as a separate update pass).
    /// </summary>
    procedure UpdateDualTail(const dt: Single);

    /// <summary>
    /// Renders all active dual-tail particles as additive billboards.
    /// Call from TSpaceWorld.RenderCometParticles or as a separate
    /// render pass inside BeginMode3D.
    /// </summary>
    procedure RenderDualTail(const CamRight, CamUp: TVector3);

    /// <summary>
    /// Clears all dual-tail particles. Call on scene reset or when
    /// the player jumps between star systems.
    /// </summary>
    procedure ClearDualTail;

    // --- Sun corona shader (optional, lazy-init) -----------------------

    /// <summary>
    /// Loads the sun corona shader. Returns True if the shader is ready.
    /// Safe to call multiple times - subsequent calls are no-ops.
    /// </summary>
    function InitSunCorona: Boolean;

    /// <summary>
    /// Renders a flowing-plasma corona sphere around the sun. Call from
    /// TSpaceWorld.RenderSuns after the solid sun core is drawn. The
    /// shader is lazy-initialized on first call.
    /// </summary>
    procedure RenderSunCorona(const SunPos: TVector3; SunRadius: Single;
      const SunColor: TColorB);

    /// <summary>
    /// Releases the corona shader. Called automatically by Destroy.
    /// Safe to call manually if you want to free GPU memory mid-session.
    /// </summary>
    procedure ShutdownSunCorona;

    // --- Diagnostics ----------------------------------------------------
    property GalaxyCount: Integer read GetGalaxyCount;
    property DualTailParticleCount: Integer read FDualTailCount;
    property Time: Single read FTime;
  end;

const
  // ====================================================================
  // Sun corona shader source.
  // ------------------------------------------------------------------------
  // 3-octave value noise sampled on a sphere, animated via the time
  // uniform. Produces flowing plasma streaks without the cost of a full
  // fluid simulation. The tint uniform mixes the sun's color into the
  // noise so the corona always matches the sun visually.
  // ====================================================================
  SUN_CORONA_VERT: AnsiString =
    '#version 330' + #10 +
    'in vec3 vertexPosition;' + #10 +
    'uniform mat4 mvp;' + #10 +
    'out vec3 vLocalPos;' + #10 +
    'void main() {' + #10 +
    '  vLocalPos = vertexPosition;' + #10 +
    '  gl_Position = mvp * vec4(vertexPosition, 1.0);' + #10 +
    '}';

  SUN_CORONA_FRAG: AnsiString =
    '#version 330' + #10 +
    'in vec3 vLocalPos;' + #10 +
    'uniform float time;' + #10 +
    'uniform vec3  tint;' + #10 +
    'out vec4 fragColor;' + #10 +
    'float hash(vec3 p) {' + #10 +
    '  p = fract(p * 0.3183099 + 0.1);' + #10 +
    '  p *= 17.0;' + #10 +
    '  return fract(p.x*p.y*p.z*(p.x+p.y+p.z));' + #10 +
    '}' + #10 +
    'float noise(vec3 p) {' + #10 +
    '  vec3 i = floor(p); vec3 f = fract(p);' + #10 +
    '  f = f*f*(3.0-2.0*f);' + #10 +
    '  return mix(mix(mix(hash(i+vec3(0,0,0)), hash(i+vec3(1,0,0)), f.x),' + #10 +
    '                 mix(hash(i+vec3(0,1,0)), hash(i+vec3(1,1,0)), f.x), f.y),' + #10 +
    '             mix(mix(hash(i+vec3(0,0,1)), hash(i+vec3(1,0,1)), f.x),' + #10 +
    '                 mix(hash(i+vec3(0,1,1)), hash(i+vec3(1,1,1)), f.x), f.y), f.z);' + #10 +
    '}' + #10 +
    'void main() {' + #10 +
    '  vec3 p = normalize(vLocalPos);' + #10 +
    '  float n = noise(p*4.0 + vec3(0.0, 0.0, time*0.3))*0.55' + #10 +
    '          + noise(p*9.0 - vec3(time*0.2, 0.0, 0.0))*0.30' + #10 +
    '          + noise(p*18.0 + vec3(time*0.5))*0.15;' + #10 +
    '  float intensity = pow(n, 1.4);' + #10 +
    '  fragColor = vec4(tint * (0.6 + intensity*1.4), 0.55 + intensity*0.4);' + #10 +
    '}';

implementation

{ TSpaceVisuals }

constructor TSpaceVisuals.Create;
begin
  inherited Create;
  FRngState := 1337;
  FTime := 0;
  FDualTailCount := 0;
  SetLength(FDualTailParticles, DUAL_TAIL_MAX_PARTICLES);
  FCoronaShader.id := 0;
  FCoronaTimeLoc := -1;
  FCoronaColorLoc := -1;
  FCoronaInitialized := False;
end;

destructor TSpaceVisuals.Destroy;
begin
  ShutdownSunCorona;
  FGalaxies := nil;
  FDualTailParticles := nil;
  inherited;
end;

// ============================================================================
// Internal RNG - xorshift32, deterministic, no allocation.
// ============================================================================

procedure TSpaceVisuals.SeedRand(Seed: Cardinal);
begin
  if Seed = 0 then
    Seed := 1;
  FRngState := Seed;
end;

function TSpaceVisuals.NextRand: Single;
begin
  FRngState := FRngState xor (FRngState shl 13);
  FRngState := FRngState xor (FRngState shr 17);
  FRngState := FRngState xor (FRngState shl 5);
  Result := (FRngState and $00FFFFFF) / $00FFFFFF;
end;

// ============================================================================
// Property getters.
// ============================================================================
// Delphi property readers must be a field name or a parameterless method.
// Using Length(FGalaxies) directly in the read clause is illegal syntax
// (E2168) and - worse - corrupts parsing of the rest of the class so
// that subsequent references to FGalaxies in the implementation also
// fail with cascading E2008/E2033 errors. Routing through a proper
// getter method is the clean fix.

function TSpaceVisuals.GetGalaxyCount: Integer;
begin
  Result := Length(FGalaxies);
end;

// ============================================================================
// Stellar colors - Harvard spectral classification.
// ----------------------------------------------------------------------------
// Real star colors follow a continuous temperature curve. These 7 discrete
// samples approximate that curve well enough for visual use:
//   O (30kK+)  - deep blue
//   B (10-30kK) - blue-white
//   A (7.5-10kK) - white
//   F (6-7.5kK) - yellow-white
//   G (5.2-6kK)  - yellow (Sun is G2)
//   K (3.7-5.2kK) - orange
//   M (2.4-3.7kK) - red-orange
// ============================================================================

function TSpaceVisuals.GetStarColorStellar(ClassIndex: Byte; Alpha: Byte): TColorB;
begin
  case ClassIndex of
    0: begin Result.r := 155; Result.g := 176; Result.b := 255; end;  // O - blue
    1: begin Result.r := 170; Result.g := 191; Result.b := 255; end;  // B - blue-white
    2: begin Result.r := 202; Result.g := 215; Result.b := 255; end;  // A - white
    3: begin Result.r := 248; Result.g := 247; Result.b := 255; end;  // F - yellow-white
    4: begin Result.r := 255; Result.g := 244; Result.b := 234; end;  // G - yellow (Sun)
    5: begin Result.r := 255; Result.g := 210; Result.b := 161; end;  // K - orange
    6: begin Result.r := 255; Result.g := 204; Result.b := 111; end;  // M - red-orange
  else
    begin Result.r := 255; Result.g := 255; Result.b := 255; end;
  end;
  Result.a := Alpha;
end;

// ============================================================================
// Distant spiral galaxy generator.
// ----------------------------------------------------------------------------
// Builds one spiral galaxy on the celestial sphere using:
//   - Exponential disk profile:  p(r) ~ exp(-r/scaleLength)
//   - Logarithmic spiral arms:   theta = arm_base + tightness * ln(r)
//   - Gaussian Z thickness:      bulge is fatter in the center
//   - Spectral color bias:       bulge = old yellow/red, arms = young blue
// ============================================================================

procedure TSpaceVisuals.GenerateGalaxy(var Galaxy: TDistantGalaxy;
  const CenterDir: TVector3; AngularRadius: Single;
  StarCount: Integer; ArmCount: Integer; const Tint: TColorB);
var
  I: Integer;
  LocalR, Angle, Z, U: Single;
  TangentX, TangentY: TVector3;
  St: ^TDistantGalaxyStar;
  InArm: Boolean;
  ArmIdx: Integer;
  LocalR_Angular, Z_Angular: Single;
  ColorBias: Byte;
  BrightnessMod: Single;
  Pos: TVector3;
begin
  Galaxy.CenterDir := CenterDir;
  Galaxy.AngularRadius := AngularRadius;
  Galaxy.ArmCount := ArmCount;
  Galaxy.TintR := Tint.r;
  Galaxy.TintG := Tint.g;
  Galaxy.TintB := Tint.b;

  // Build orthonormal basis (TangentX, TangentY) perpendicular to
  // CenterDir so the galaxy disk lies in a plane perpendicular to the
  // line of sight. This keeps the galaxy "face-on" to the camera.
  if Abs(CenterDir.y) < 0.9 then
    TangentX := Vector3Normalize(Vector3CrossProduct(CenterDir, Vector3Create(0, 1, 0)))
  else
    TangentX := Vector3Normalize(Vector3CrossProduct(CenterDir, Vector3Create(1, 0, 0)));
  TangentY := Vector3Normalize(Vector3CrossProduct(CenterDir, TangentX));

  SetLength(Galaxy.Stars, StarCount);

  for I := 0 to StarCount - 1 do
  begin
    St := @Galaxy.Stars[I];

    // 35% chance: star lives in a spiral arm
    InArm := (NextRand < GALAXY_ARM_FRACTION) and (ArmCount > 0);

    if InArm then
    begin
      // Pick one of N arms. Each arm has a base angle of 2*pi*idx/N.
      ArmIdx := Trunc(NextRand * ArmCount);
      Angle := (ArmIdx / ArmCount) * 2.0 * PI;

      // Sample radius from exponential disk profile
      U := NextRand;
      LocalR := -GALAXY_DISK_SCALE_FRAC * Ln(1.0 - U * 0.95);

      // Logarithmic spiral: theta = arm_base + tightness * ln(r * 4)
      // The *4 maps LocalR in [0, 1] to a reasonable logarithm range.
      Angle := Angle + GALAXY_ARM_TIGHTNESS * Ln(Max(LocalR, 0.001) * 4.0);

      // Scatter perpendicular to the arm so it has visible width
      LocalR := LocalR + (NextRand - 0.5) * 0.06;
      Angle := Angle + (NextRand - 0.5) * 0.18;
    end
    else
    begin
      // Exponential disk: inverse CDF of p(r) = (1/scale) * exp(-r/scale)
      U := NextRand;
      LocalR := -GALAXY_DISK_SCALE_FRAC * Ln(1.0 - U * 0.99);
      Angle := NextRand * 2.0 * PI;
    end;

    // Clamp to unit disk [0, 1]
    if LocalR > 1.0 then LocalR := 1.0;
    if LocalR < 0.0 then LocalR := 0.0;

    // Gaussian Z thickness - bulge is fatter in center, thins out at edge
    U := NextRand;
    if U < 1e-6 then U := 1e-6;
    Z := Sqrt(-2.0 * Ln(U)) * Cos(2.0 * PI * NextRand)
       * GALAXY_THICKNESS_FRAC
       * Exp(-LocalR / 0.3);

    // Map unit-disk (LocalR, Angle, Z) to angular offset on the sky
    LocalR_Angular := LocalR * AngularRadius;
    Z_Angular := Z * AngularRadius;

    // Build 3D offset in the galaxy plane, then add to CenterDir to get
    // the final direction on the celestial sphere. Using small-angle
    // approximation here since AngularRadius is small (~0.05 rad).
    Pos := Vector3Add(
             Vector3Add(
               Vector3Scale(TangentX, Cos(Angle) * LocalR_Angular),
               Vector3Scale(TangentY, Sin(Angle) * LocalR_Angular)),
             Vector3Scale(CenterDir, Z_Angular));
    St^.Dir := Vector3Normalize(Vector3Add(Pos, CenterDir));

    // Spectral color bias:
    //   - Bulge (r < 0.18): old population -> G, K, M (yellow/orange/red)
    //   - Spiral arms     : young population -> O, B, A (blue)
    //   - Disk (rest)     : intermediate -> F, G, K (whitish-yellow)
    // This matches real galactic color profiles.
    if LocalR < GALAXY_BULGE_RADIUS_FRAC then
      ColorBias := 4 + Trunc(NextRand * 3)
    else if InArm then
      ColorBias := Trunc(NextRand * 3)
    else
      ColorBias := 3 + Trunc(NextRand * 3);
    St^.ColorTint := ColorBias;

    // Brightness falls off from center, with extra bulge boost
    BrightnessMod := 1.0 - (LocalR * 0.6);
    if LocalR < GALAXY_BULGE_RADIUS_FRAC then
      BrightnessMod := BrightnessMod + 0.4 * (1.0 - LocalR / GALAXY_BULGE_RADIUS_FRAC);
    St^.Brightness := EnsureRange(BrightnessMod, 0.15, 1.0);

    // Smaller stars in arms, brighter in bulge (matches real luminosity)
    if LocalR < GALAXY_BULGE_RADIUS_FRAC then
      St^.Size := 2.5 + NextRand * 3.0
    else
      St^.Size := 1.2 + NextRand * NextRand * 3.0;

    St^.TwinklePhase := NextRand * 2.0 * PI;
    St^.TwinkleSpeed := 0.3 + NextRand * 1.8;
  end;
end;

procedure TSpaceVisuals.InitializeGalaxies(Count: Integer; StarsPerGalaxy: Integer);
var
  // Fixed seed directions spread across the celestial sphere so the
  // galaxies always appear in the same places across runs. Picked by
  // hand to avoid clustering in one hemisphere and to keep at least
  // one galaxy visible from any reasonable camera orientation.
  // Initialized at runtime via Vector3Create() instead of using
  // record-constant syntax, which would require knowing Raylib's
  // exact TVector3 field layout at compile time.
  FixedDirs: array[0..7] of TVector3;
  FixedDirCount: Integer;
  I: Integer;
  Dir: TVector3;
  Tint: TColorB;
  Radius: Single;
  Arms: Integer;
begin
  // Build the fixed direction table at runtime - safe regardless of
  // how Raylib's TVector3 is laid out internally.
  FixedDirs[0] := Vector3Create( 0.32,  0.45,  0.83);
  FixedDirs[1] := Vector3Create(-0.71,  0.21,  0.67);
  FixedDirs[2] := Vector3Create( 0.58, -0.62,  0.52);
  FixedDirs[3] := Vector3Create(-0.42, -0.38,  0.82);
  FixedDirs[4] := Vector3Create( 0.18,  0.78, -0.60);
  FixedDirs[5] := Vector3Create(-0.85,  0.32, -0.42);
  FixedDirs[6] := Vector3Create( 0.71, -0.21, -0.67);
  FixedDirs[7] := Vector3Create(-0.18, -0.78, -0.60);
  FixedDirCount := Length(FixedDirs);

  SetLength(FGalaxies, Count);
  SeedRand(424242);  // Deterministic so galaxy layout is stable across runs

  for I := 0 to Count - 1 do
  begin
    if I < FixedDirCount then
      Dir := Vector3Normalize(FixedDirs[I])
    else
    begin
      // Fallback for Count > 8: random direction on sphere
      Dir := Vector3Normalize(Vector3Create(
        NextRand * 2 - 1, NextRand * 2 - 1, NextRand * 2 - 1));
    end;

    // Vary tint per galaxy (some redshifted, some bluish, some neutral)
    case I mod 4 of
      0: begin Tint.r := 255; Tint.g := 240; Tint.b := 220; end;  // Warm white
      1: begin Tint.r := 255; Tint.g := 200; Tint.b := 180; end;  // Redshift
      2: begin Tint.r := 220; Tint.g := 230; Tint.b := 255; end;  // Blueshift
      3: begin Tint.r := 255; Tint.g := 255; Tint.b := 255; end;  // Pure white
    end;
    Tint.a := 255;

    // Vary size and arm count so the galaxies don't all look identical
    Radius := GALAXY_ANGULAR_RADIUS * (0.7 + NextRand * 0.6);
    Arms := 1 + (I mod 3);  // Cycle: 1, 2, 3, 1, 2, 3, ...

    GenerateGalaxy(FGalaxies[I], Dir, Radius, StarsPerGalaxy, Arms, Tint);
  end;
end;

procedure TSpaceVisuals.Update(const dt: Single);
begin
  FTime := FTime + dt;
end;

// ============================================================================
// Star sprites.
// ----------------------------------------------------------------------------
// Two flavors:
//   - DrawStarSprite4: original Yutani style (4-point cross)
//   - DrawStarSprite6: telescope-photo style (6-point diffraction spikes)
// Both are billboard triangles fading from a bright center to transparent
// tips, drawn via rlBegin/rlVertex3f so they batch efficiently.
// ============================================================================

procedure TSpaceVisuals.DrawStarSprite4(const Pos, CamRight, CamUp: TVector3;
  Size: Single; Col: TColorB; Alpha: Byte);
var
  H: Single;
  TopV, RightV, BottomV, LeftV: TVector3;
begin
  H := Size * 0.5;
  TopV    := Vector3Add(Pos, Vector3Scale(CamUp,    H));
  RightV  := Vector3Add(Pos, Vector3Scale(CamRight, H));
  BottomV := Vector3Subtract(Pos, Vector3Scale(CamUp,    H));
  LeftV   := Vector3Subtract(Pos, Vector3Scale(CamRight, H));

  // 4 triangles fanning out from the bright center to the 4 cardinal
  // tips, each fading to transparent at the tip.
  rlColor4ub(Col.r, Col.g, Col.b, Alpha);
  rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);
  rlVertex3f(TopV.x, TopV.y, TopV.z);
  rlVertex3f(RightV.x, RightV.y, RightV.z);

  rlColor4ub(Col.r, Col.g, Col.b, Alpha);
  rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);
  rlVertex3f(RightV.x, RightV.y, RightV.z);
  rlVertex3f(BottomV.x, BottomV.y, BottomV.z);

  rlColor4ub(Col.r, Col.g, Col.b, Alpha);
  rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);
  rlVertex3f(BottomV.x, BottomV.y, BottomV.z);
  rlVertex3f(LeftV.x, LeftV.y, LeftV.z);

  rlColor4ub(Col.r, Col.g, Col.b, Alpha);
  rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);
  rlVertex3f(LeftV.x, LeftV.y, LeftV.z);
  rlVertex3f(TopV.x, TopV.y, TopV.z);
end;

procedure TSpaceVisuals.DrawStarSprite6(const Pos, CamRight, CamUp: TVector3;
  Size: Single; Col: TColorB; Alpha: Byte);
var
  SpikeLen, Ang: Single;
  R, U, C: TVector3;
  Sp: array[0..5] of TVector3;
  I: Integer;
  Ex, Ey: Single;
begin
  // 6-point diffraction-spike star sprite. Renders 6 spike triangles
  // fanning out from a bright center, each fading to transparent at
  // the tip. This produces the characteristic "telescope photograph"
  // pattern that real long-exposure star images show.
  SpikeLen := Size * STAR_SPIKE_LEN_MULT;
  R := CamRight;
  U := CamUp;
  C := Pos;

  // Pre-compute 6 spike tip positions (every 60 degrees around the
  // camera-facing plane).
  for I := 0 to 5 do
  begin
    Ang := (I / 6.0) * 2.0 * PI;
    Ex := Cos(Ang) * SpikeLen;
    Ey := Sin(Ang) * SpikeLen;
    Sp[I].x := C.x + R.x * Ex + U.x * Ey;
    Sp[I].y := C.y + R.y * Ex + U.y * Ey;
    Sp[I].z := C.z + R.z * Ex + U.z * Ey;
  end;

  // 6 spike triangles, each: center (bright) -> spike[i] (fade) -> spike[i+1] (fade)
  for I := 0 to 5 do
  begin
    rlColor4ub(Col.r, Col.g, Col.b, Alpha);
    rlVertex3f(C.x, C.y, C.z);
    rlColor4ub(Col.r, Col.g, Col.b, 0);
    rlVertex3f(Sp[I].x, Sp[I].y, Sp[I].z);
    rlColor4ub(Col.r, Col.g, Col.b, 0);
    rlVertex3f(Sp[(I + 1) mod 6].x, Sp[(I + 1) mod 6].y, Sp[(I + 1) mod 6].z);
  end;
end;

// ============================================================================
// Distant galaxy rendering.
// ----------------------------------------------------------------------------
// Renders all galaxies as additive billboard stars on the celestial sphere.
// Uses DrawStarSprite4 (cheaper) since the galaxies are far away and the
// 6-point spikes would just add visual noise at this scale.
// ============================================================================

procedure TSpaceVisuals.RenderDistantGalaxies(const CameraPos, CamRight, CamUp: TVector3);
var
  G, I: Integer;
  Galaxy: ^TDistantGalaxy;
  St: ^TDistantGalaxyStar;
  Pos: TVector3;
  Twinkle, AlphaF: Single;
  AlphaB: Byte;
  Col, Tinted: TColorB;
begin
  if Length(FGalaxies) = 0 then
    Exit;

  rlDisableDepthTest;
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    for G := 0 to High(FGalaxies) do
    begin
      Galaxy := @FGalaxies[G];

      for I := 0 to High(Galaxy^.Stars) do
      begin
        St := @Galaxy^.Stars[I];

        // Place each galaxy star on the celestial sphere at fixed
        // distance. This makes the galaxy appear "infinitely far away".
        Pos := Vector3Add(CameraPos, Vector3Scale(St^.Dir, DISTANT_SHELL_RADIUS_VIS));

        Twinkle := 0.7 + 0.3 * Sin(FTime * St^.TwinkleSpeed + St^.TwinklePhase);
        AlphaF := St^.Brightness * Twinkle;
        AlphaB := Trunc(EnsureRange(AlphaF * 255, 0, 255));

        // Get spectral color then apply galaxy tint (redshift etc.)
        Col := GetStarColorStellar(St^.ColorTint, 255);
        Tinted.r := (Col.r * Galaxy^.TintR) shr 8;
        Tinted.g := (Col.g * Galaxy^.TintG) shr 8;
        Tinted.b := (Col.b * Galaxy^.TintB) shr 8;
        Tinted.a := 255;

        // Faint outer glow + bright inner core for each star
        DrawStarSprite4(Pos, CamRight, CamUp, St^.Size * 3.0, Tinted, Trunc(AlphaB * 0.12));
        DrawStarSprite4(Pos, CamRight, CamUp, St^.Size, Tinted, AlphaB);
      end;
    end;
  finally
    rlEnd;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
  rlEnableBackfaceCulling;
  rlEnableDepthTest;
end;

// ============================================================================
// Dual-tail comet particle system.
// ----------------------------------------------------------------------------
// Real comets have two distinct tails when close to a star:
//   - Ion tail: blue, straight, fast - pushed directly away from the sun
//     by solar wind. Almost no orbital lag.
//   - Dust tail: yellow-white, curved, slow - pushed by radiation pressure
//     but lags behind orbital motion, producing the characteristic curve.
// The two tails combined are what makes a comet visually iconic.
// ============================================================================

procedure TSpaceVisuals.SpawnDualTail(const CometPos, CometVel: TVector3;
  CometSize: Single; const NearestSunPos: TVector3; ParticlesPerCall: Integer);
var
  ToSun, RadialDir, PerpDir: TVector3;
  SunDist, RadiationPressure: Single;
  I: Integer;
  TailVel: TVector3;
  IsIonTail: Boolean;
  P: ^TDualTailParticle;
begin
  // Find direction from comet away from sun (radiation pressure direction)
  ToSun := Vector3Subtract(NearestSunPos, CometPos);
  SunDist := Vector3Length(ToSun);
  if SunDist < 1.0 then
    Exit;
  RadialDir := Vector3Scale(ToSun, -1.0 / SunDist);  // Away from sun

  // Radiation pressure falls off with square of distance (Poynting-Robertson)
  RadiationPressure := EnsureRange(
    DUAL_TAIL_RADIATION_CONSTANT / (SunDist * SunDist), 0.3, 40.0);

  // Perpendicular vector for dust-tail curvature. Cross with any axis
  // that is not parallel to RadialDir.
  if Abs(RadialDir.y) < 0.9 then
    PerpDir := Vector3Normalize(Vector3CrossProduct(RadialDir, Vector3Create(0, 1, 0)))
  else
    PerpDir := Vector3Normalize(Vector3CrossProduct(RadialDir, Vector3Create(1, 0, 0)));

  for I := 0 to ParticlesPerCall - 1 do
  begin
    if FDualTailCount >= DUAL_TAIL_MAX_PARTICLES then
      Exit;

    IsIonTail := (I and 1) = 0;  // Alternate: even = ion, odd = dust

    P := @FDualTailParticles[FDualTailCount];
    Inc(FDualTailCount);

    P^.Active := True;
    // Spawn near comet with small random scatter so the tail has thickness
    P^.Position := Vector3Add(CometPos,
      Vector3Create((NextRand - 0.5) * 4,
                    (NextRand - 0.5) * 4,
                    (NextRand - 0.5) * 4));

    if IsIonTail then
    begin
      // Ion tail: blue, straight, fast. Pushed directly away from sun
      // with minimal orbital lag.
      TailVel := Vector3Add(
        Vector3Scale(RadialDir, RadiationPressure * DUAL_TAIL_ION_PRESSURE),
        Vector3Scale(CometVel, DUAL_TAIL_ION_LAG));
      P^.Velocity := TailVel;
      P^.MaxLife := 0.8 + NextRand * 0.8;
      P^.Size := CometSize * (0.6 + NextRand * 0.5);
      P^.TailKind := tkIon;
    end
    else
    begin
      // Dust tail: warm yellow, curved, slow. Pushed by radiation
      // pressure but lags behind orbital motion. Perpendicular drift
      // gives the characteristic curve.
      TailVel := Vector3Add(
        Vector3Scale(RadialDir, RadiationPressure * DUAL_TAIL_DUST_PRESSURE),
        Vector3Scale(CometVel, DUAL_TAIL_DUST_LAG));
      TailVel := Vector3Add(TailVel,
        Vector3Scale(PerpDir, RadiationPressure * 0.25 * (NextRand - 0.5)));
      P^.Velocity := TailVel;
      P^.MaxLife := 1.5 + NextRand * 1.5;
      P^.Size := CometSize * (0.8 + NextRand * 0.6);
      P^.TailKind := tkDust;
    end;

    P^.Life := P^.MaxLife;
  end;
end;

procedure TSpaceVisuals.UpdateDualTail(const dt: Single);
var
  I, WriteIdx: Integer;
  P: ^TDualTailParticle;
begin
  // Update + compact in a single pass. Dead particles are removed by
  // swapping them out with the next live one, keeping the active
  // region of the array contiguous at the front. This is O(n) per
  // frame and keeps render loops branchless.
  WriteIdx := 0;
  for I := 0 to FDualTailCount - 1 do
  begin
    if not FDualTailParticles[I].Active then
      Continue;

    P := @FDualTailParticles[I];
    P^.Life := P^.Life - dt;

    if P^.Life <= 0 then
      Continue;

    // Velocity drag (different per tail kind - ion decays faster)
    if P^.TailKind = tkIon then
      P^.Velocity := Vector3Scale(P^.Velocity, 1.0 - DUAL_TAIL_ION_DRAG * dt)
    else
      P^.Velocity := Vector3Scale(P^.Velocity, 1.0 - DUAL_TAIL_DUST_DRAG * dt);

    P^.Position := Vector3Add(P^.Position, Vector3Scale(P^.Velocity, dt));

    // Move to write position if needed (compact)
    if WriteIdx <> I then
      FDualTailParticles[WriteIdx] := FDualTailParticles[I];
    Inc(WriteIdx);
  end;

  // Mark the now-unused tail of the array as inactive (safety)
  for I := WriteIdx to FDualTailCount - 1 do
    FDualTailParticles[I].Active := False;

  FDualTailCount := WriteIdx;
end;

procedure TSpaceVisuals.RenderDualTail(const CamRight, CamUp: TVector3);
var
  I: Integer;
  P: ^TDualTailParticle;
  Progress, AlphaF, HalfSize: Single;
  AlphaB: Byte;
  R, G, B: Byte;
  RX, RY, RZ, UX, UY, UZ, Px, Py, Pz: Single;
begin
  if FDualTailCount = 0 then
    Exit;

  // Cache camera basis vectors to locals so the inner loop doesn't do
  // field lookups per vertex.
  RX := CamRight.x; RY := CamRight.y; RZ := CamRight.z;
  UX := CamUp.x;    UY := CamUp.y;    UZ := CamUp.z;

  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    for I := 0 to FDualTailCount - 1 do
    begin
      P := @FDualTailParticles[I];
      Progress := 1.0 - (P^.Life / P^.MaxLife);

      // Color gradient over lifetime. Ion fades from blue-white to
      // deep blue; dust fades from warm yellow to deep orange-red.
      if P^.TailKind = tkIon then
      begin
        R := Trunc(Lerp(220,  60, Progress));
        G := Trunc(Lerp(230, 100, Progress));
        B := Trunc(Lerp(255, 200, Progress));
      end
      else
      begin
        R := Trunc(Lerp(255, 180, Progress));
        G := Trunc(Lerp(230,  80, Progress));
        B := Trunc(Lerp(180,  40, Progress));
      end;

      AlphaF := (1.0 - Progress) * 0.8;
      AlphaB := Trunc(EnsureRange(AlphaF * 255, 0, 255));

      // Particles shrink slightly as they age
      HalfSize := (P^.Size * (1.0 - Progress * 0.5)) * 0.5;

      Px := P^.Position.x;
      Py := P^.Position.y;
      Pz := P^.Position.z;

      // Two-triangle billboard quad facing the camera
      rlColor4ub(R, G, B, AlphaB);
      rlVertex3f(Px - RX*HalfSize + UX*HalfSize,
                 Py - RY*HalfSize + UY*HalfSize,
                 Pz - RZ*HalfSize + UZ*HalfSize);
      rlVertex3f(Px + RX*HalfSize + UX*HalfSize,
                 Py + RY*HalfSize + UY*HalfSize,
                 Pz + RZ*HalfSize + UZ*HalfSize);
      rlVertex3f(Px + RX*HalfSize - UX*HalfSize,
                 Py + RY*HalfSize - UY*HalfSize,
                 Pz + RZ*HalfSize - UZ*HalfSize);

      rlColor4ub(R, G, B, AlphaB);
      rlVertex3f(Px - RX*HalfSize + UX*HalfSize,
                 Py - RY*HalfSize + UY*HalfSize,
                 Pz - RZ*HalfSize + UZ*HalfSize);
      rlVertex3f(Px + RX*HalfSize - UX*HalfSize,
                 Py + RY*HalfSize - UY*HalfSize,
                 Pz + RZ*HalfSize - UZ*HalfSize);
      rlVertex3f(Px - RX*HalfSize - UX*HalfSize,
                 Py - RY*HalfSize - UY*HalfSize,
                 Pz - RZ*HalfSize - UZ*HalfSize);
    end;
  finally
    rlEnd;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
  rlEnableBackfaceCulling;
end;

procedure TSpaceVisuals.ClearDualTail;
var
  I: Integer;
begin
  for I := 0 to High(FDualTailParticles) do
    FDualTailParticles[I].Active := False;
  FDualTailCount := 0;
end;

// ============================================================================
// Sun corona shader (optional, lazy-init).
// ----------------------------------------------------------------------------
// Loads a 3-octave value-noise shader on first use and renders it as an
// additive sphere around the sun position. The shader produces flowing
// plasma streaks without the cost of a real fluid simulation.
// ============================================================================

function TSpaceVisuals.InitSunCorona: Boolean;
begin
  if FCoronaInitialized then
    Exit(FCoronaShader.id > 0);

  FCoronaInitialized := True;
  FCoronaShader := LoadShaderFromMemory(
    PAnsiChar(SUN_CORONA_VERT),
    PAnsiChar(SUN_CORONA_FRAG));

  if FCoronaShader.id > 0 then
  begin
    FCoronaTimeLoc  := GetShaderLocation(FCoronaShader, 'time');
    FCoronaColorLoc := GetShaderLocation(FCoronaShader, 'tint');
    Result := True;
  end
  else
  begin
    FCoronaTimeLoc := -1;
    FCoronaColorLoc := -1;
    Result := False;
  end;
end;

procedure TSpaceVisuals.RenderSunCorona(const SunPos: TVector3; SunRadius: Single;
  const SunColor: TColorB);
var
  TimeArr: array[0..0] of Single;
  TintArr: array[0..2] of Single;
begin
  if not FCoronaInitialized then
    InitSunCorona;
  if FCoronaShader.id = 0 then
    Exit;

  TimeArr[0] := FTime;
  TintArr[0] := SunColor.r / 255.0;
  TintArr[1] := SunColor.g / 255.0;
  TintArr[2] := SunColor.b / 255.0;

  if FCoronaTimeLoc >= 0 then
    SetShaderValue(FCoronaShader, FCoronaTimeLoc, @TimeArr, SHADER_UNIFORM_FLOAT);
  if FCoronaColorLoc >= 0 then
    SetShaderValue(FCoronaShader, FCoronaColorLoc, @TintArr, SHADER_UNIFORM_VEC3);

  rlSetBlendMode(BLEND_ADDITIVE);
  rlDisableDepthMask;  // Don't write to depth - aura should not occlude
  BeginShaderMode(FCoronaShader);
  try
    DrawSphere(SunPos, SunRadius * 1.15, WHITE);
  finally
    EndShaderMode;
    rlEnableDepthMask;
    rlSetBlendMode(BLEND_ALPHA);
  end;
end;

procedure TSpaceVisuals.ShutdownSunCorona;
begin
  if FCoronaShader.id > 0 then
  begin
    UnloadShader(FCoronaShader);
    FCoronaShader.id := 0;
  end;
  FCoronaInitialized := False;
  FCoronaTimeLoc := -1;
  FCoronaColorLoc := -1;
end;

end.
