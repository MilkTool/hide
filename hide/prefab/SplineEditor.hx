package hide.prefab;
import hxd.Key as K;
import hrt.prefab.l3d.Spline;

#if editor

/*class SplineViewer extends h3d.scene.Object {

	public var gaphics : h3d.scene.Graphics;

	public function new( s : Spline ) {
		super(s);
		gaphics = new h3d.scene.Graphics(this);
		gaphics.lineStyle(4, 0xffffff);
		gaphics.material.mainPass.setPassName("overlay");
		gaphics.material.mainPass.depth(false, LessEqual);
		gaphics.ignoreParentTransform = false;
		gaphics.clear();
		gaphics.moveTo(1, 0, 0);
		gaphics.lineTo(-1, 0, 0);
	}
}*/

class NewSplinePointViewer extends h3d.scene.Object {

	var pointViewer : h3d.scene.Mesh;
	var connectionViewer : h3d.scene.Graphics;

	public function new( parent : h3d.scene.Object ) {
		super(parent);
		name = "SplinePointViewer";
		pointViewer = new h3d.scene.Mesh(h3d.prim.Sphere.defaultUnitSphere(), null, this);
		pointViewer.name = "sphereHandle";
		pointViewer.material.setDefaultProps("ui");
		pointViewer.material.color.set(1,1,0,1);

		connectionViewer = new h3d.scene.Graphics(this);
		connectionViewer.lineStyle(4, 0xFFFF00);
		connectionViewer.material.mainPass.setPassName("overlay");
		connectionViewer.material.mainPass.depth(false, LessEqual);
		connectionViewer.ignoreParentTransform = false;
		connectionViewer.clear();
	}

	public function update( spd : SplinePointData ) {
		connectionViewer.clear();
		pointViewer.setPosition(spd.pos.x, spd.pos.y, spd.pos.z);

		// Only display the connection if we are adding the new point at the end or the beggining fo the spline
		connectionViewer.visible = spd.prev == spd.next;
		if( connectionViewer.visible ) {
			var startPos = spd.prev == null ? spd.next.getPoint() : spd.prev.getPoint();
			connectionViewer.moveTo(startPos.x, startPos.y, startPos.z);
			connectionViewer.lineTo(spd.pos.x, spd.pos.y, spd.pos.z);
		}
	}
}

class SplinePointViewer extends h3d.scene.Object {

	var pointViewer : h3d.scene.Mesh;
	var controlPointsViewer : h3d.scene.Graphics;

	public function new( sp : SplinePoint ) {
		super(sp);
		name = "SplinePointViewer";
		pointViewer = new h3d.scene.Mesh(h3d.prim.Sphere.defaultUnitSphere(), null, this);
		pointViewer.name = "sphereHandle";
		pointViewer.material.setDefaultProps("ui");

		controlPointsViewer = new h3d.scene.Graphics(this);
		controlPointsViewer.lineStyle(4, 0xffffff);
		controlPointsViewer.material.mainPass.setPassName("overlay");
		controlPointsViewer.material.mainPass.depth(false, LessEqual);
		controlPointsViewer.ignoreParentTransform = false;
		controlPointsViewer.clear();
		controlPointsViewer.moveTo(1, 0, 0);
		controlPointsViewer.lineTo(-1, 0, 0);
	}

	override function sync( ctx : h3d.scene.RenderContext ) {
		var cam = ctx.camera;
		var gpos = getAbsPos().getPosition();
		var distToCam = cam.pos.sub(gpos).length();
		var engine = h3d.Engine.getCurrent();
		var ratio = 18 / engine.height;
		var correctionFromParents =  1.0 / getAbsPos().getScale().x;
		pointViewer.setScale(correctionFromParents * ratio * distToCam * Math.tan(cam.fovY * 0.5 * Math.PI / 180.0));
		calcAbsPos();
		super.sync(ctx);
	}

	public function interset( ray : h3d.col.Ray ) : Bool {
		return pointViewer.getCollider().rayIntersection(ray, false) != -1;
	}
}

@:access(hrt.prefab.l3d.Spline)
class SplineEditor {

	public var prefab : Spline;
	public var editContext : EditContext;
	var editMode = false;
	var undo : hide.ui.UndoHistory;

	var interactive : h2d.Interactive;

	 // Easy way to keep track of viewers
	var splinePointViewers : Array<SplinePointViewer> = [];
	var gizmos : Array<hide.view.l3d.Gizmo> = [];
	var newSplinePointViewer : NewSplinePointViewer;

	public function new( prefab : Spline, undo : hide.ui.UndoHistory ){
		this.prefab = prefab;
		this.undo = undo;
	}

	public function update( ctx : hrt.prefab.Context , ?propName : String ) {
		if( editMode ) {
			showViewers(ctx);
		}
	}

	function reset() {
		removeViewers();
		removeGizmos();
		if( interactive != null ) {
			interactive.remove();
			interactive = null;
		}
		if( newSplinePointViewer != null ) {
			newSplinePointViewer.remove();
			newSplinePointViewer = null;
		}
	}

	function trySelectPoint( ray: h3d.col.Ray ) : SplinePointViewer {
		for( spv in splinePointViewers )
			if( spv.interset(ray) )
				return spv;
		return null;
	}

	inline function getContext() {
		return editContext.getContext(prefab);
	}

	function getNewPointPosition( mouseX : Float, mouseY : Float, ctx : hrt.prefab.Context, ?precision = 1.0 ) : SplinePointData {
		var closestPt = getClosestPointFromMouse(mouseX, mouseY, ctx, precision);
		
		// If ware are adding a new point at the end/beginning, just make a raycast cursor -> plane with the transform of the frit/last SplinePoint
		if( closestPt.next == closestPt.prev ) {
			var camera = @:privateAccess ctx.local3d.getScene().camera;
			var ray = camera.rayFromScreen(mouseX, mouseY);
			var normal = closestPt.prev.getAbsPos().up();
			var plane = h3d.col.Plane.fromNormalPoint(normal.toPoint(), new h3d.col.Point(closestPt.prev.getAbsPos().tx, closestPt.prev.getAbsPos().ty, closestPt.prev.getAbsPos().tz));
			var pt = ray.intersect(plane);
			return { pos : pt, prev : closestPt.prev, next : closestPt.next };
		}
		else 
			return closestPt;
	}

	function getClosestPointFromMouse( mouseX : Float, mouseY : Float, ctx : hrt.prefab.Context, ?precision = 1.0 ) : SplinePointData {
		if( ctx == null || ctx.local3d == null || ctx.local3d.getScene() == null ) 
			return null;

		var result : SplinePointData = null;
		var mousePos = new h3d.Vector( mouseX / h3d.Engine.getCurrent().width, 1.0 - mouseY / h3d.Engine.getCurrent().height, 0);
		var length = prefab.getLength();
		var stepCount = hxd.Math.ceil(length * precision);
		var minDist = -1.0;
		for( i in 0 ... stepCount ) {
			var pt = prefab.getPoint( i / stepCount, precision);
			var screenPos = pt.pos.toVector();
			screenPos.project(ctx.local3d.getScene().camera.m);
			screenPos.z = 0;
			screenPos.scale3(0.5);
			screenPos = screenPos.add(new h3d.Vector(0.5,0.5));
			var dist = screenPos.distance(mousePos);
			if( (dist < minDist || minDist == -1) && dist < 0.1 ) {
				minDist = dist;
				result = pt;
			}
		}

		if( result == null ) {
			result = { pos : null, prev : null, next : null};

			var firstPt = prefab.points[0].getPoint();
			var firstPtScreenPos = firstPt.toVector();
			firstPtScreenPos.project(ctx.local3d.getScene().camera.m);
			firstPtScreenPos.z = 0;
			firstPtScreenPos.scale3(0.5);
			firstPtScreenPos = firstPtScreenPos.add(new h3d.Vector(0.5,0.5));
			var distToFirstPoint = firstPtScreenPos.distance(mousePos);

			var lastPt = prefab.points[prefab.points.length - 1].getPoint();
			var lastPtSreenPos = lastPt.toVector();
			lastPtSreenPos.project(ctx.local3d.getScene().camera.m);
			lastPtSreenPos.z = 0;
			lastPtSreenPos.scale3(0.5);
			lastPtSreenPos = lastPtSreenPos.add(new h3d.Vector(0.5,0.5));
			var distTolastPoint = lastPtSreenPos.distance(mousePos);

			if( distTolastPoint < distToFirstPoint ) {
				result.pos = lastPt;
				result.prev = prefab.points[prefab.points.length - 1];
				result.next = prefab.points[prefab.points.length - 1];
				minDist = distTolastPoint;
			}
			else {
				result.pos = firstPt;
				result.prev = prefab.points[0];
				result.next = prefab.points[0]; 
				minDist = distToFirstPoint;
			}
		}

		return result;
	}

	function addSplinePoint( spd : SplinePointData, ctx : hrt.prefab.Context ) {
		var invMatrix = prefab.getTransform().clone();
		invMatrix.initInverse(invMatrix);
		var pos = spd.pos.toVector();
		pos.project(invMatrix);

		var index = -1;
		if( spd.prev == spd.next ) {
			if( spd.prev ==  prefab.points[0] ) index = 0;
			else if( spd.prev ==  prefab.points[prefab.points.length - 1] ) index = prefab.points.length;
		}
		else index = prefab.points.indexOf(spd.next);

		prefab.points.insert(index, new SplinePoint(pos.x, pos.y, pos.z, ctx.local3d));
		prefab.generateBezierCurve(ctx);
	}

	function removeViewers() {
		for( v in splinePointViewers )
			v.remove();
		splinePointViewers = [];
	}

	function showViewers( ctx : hrt.prefab.Context ) {
		removeViewers(); // Security, avoid duplication
		for( sp in prefab.points ) {
			var spv = new SplinePointViewer(sp);
			splinePointViewers.push(spv);
		}
	}

	function removeGizmos() {
		for( g in gizmos ) {
			g.remove();
			@:privateAccess editContext.scene.editor.updates.remove(g.update);
		}
		gizmos = [];
	}

	function createGizmos( ctx : hrt.prefab.Context  ) {
		removeGizmos(); // Security, avoid duplication
		var sceneEditor = @:privateAccess editContext.scene.editor;
		for( sp in prefab.points ) {
			var gizmo = new hide.view.l3d.Gizmo(editContext.scene);
			gizmo.getRotationQuat().identity();
			gizmo.visible = true;
			var worldPos = ctx.local3d.localToGlobal(new h3d.Vector(sp.x, sp.y, sp.z));
			gizmo.setPosition(worldPos.x, worldPos.y, worldPos.z);
			@:privateAccess sceneEditor.updates.push( gizmo.update );
			gizmos.push(gizmo);

			gizmo.onStartMove = function(mode) {
				/**/
				var sceneObj = sp;
				var pivotPt = sceneObj.getAbsPos().getPosition();
				var pivot = new h3d.Matrix();
				pivot.initTranslation(pivotPt.x, pivotPt.y, pivotPt.z);
				var invPivot = pivot.clone();
				invPivot.invert();
				var worldMat : h3d.Matrix = sceneEditor.worldMat(sceneObj);
				var localMat : h3d.Matrix = worldMat.clone();
				localMat.multiply(localMat, invPivot);

				var posQuant = @:privateAccess sceneEditor.view.config.get("sceneeditor.xyzPrecision");
				var scaleQuant = @:privateAccess sceneEditor.view.config.get("sceneeditor.scalePrecision");
				var rotQuant = @:privateAccess sceneEditor.view.config.get("sceneeditor.rotatePrecision");

				inline function quantize(x: Float, step: Float) {
					if(step > 0) {
						x = Math.round(x / step) * step;
						x = untyped parseFloat(x.toFixed(5)); // Snap to closest nicely displayed float :cold_sweat:
					}
					return x;
				}

				var rot = sceneObj.getRotationQuat().toEuler();
				var prevState = { 	x : sceneObj.x, y : sceneObj.y, z : sceneObj.z, 
									scaleX : sceneObj.scaleX, scaleY : sceneObj.scaleY, scaleZ : sceneObj.scaleZ, 
									rotationX : rot.x, rotationY : rot.y, rotationZ : rot.z };

				gizmo.onMove = function(translate: h3d.Vector, rot: h3d.Quat, scale: h3d.Vector) {
					var transf = new h3d.Matrix();
					transf.identity();

					if(rot != null)
						rot.toMatrix(transf);

					if(translate != null)
						transf.translate(translate.x, translate.y, translate.z);

					var newMat = localMat.clone();
					newMat.multiply(newMat, transf);
					newMat.multiply(newMat, pivot);
					var invParent = sceneObj.parent.getAbsPos().clone();
					invParent.invert();
					newMat.multiply(newMat, invParent);
					if(scale != null) {
						newMat.prependScale(scale.x, scale.y, scale.z);
					}

					var rot = newMat.getEulerAngles();
					sceneObj.x = quantize(newMat.tx, posQuant);
					sceneObj.y = quantize(newMat.ty, posQuant);
					sceneObj.z = quantize(newMat.tz, posQuant);
					sceneObj.setRotation(hxd.Math.degToRad(quantize(hxd.Math.radToDeg(rot.x), rotQuant)), hxd.Math.degToRad(quantize(hxd.Math.radToDeg(rot.y), rotQuant)), hxd.Math.degToRad(quantize(hxd.Math.radToDeg(rot.z), rotQuant)));
					if(scale != null) {
						inline function scaleSnap(x: Float) {
							if(K.isDown(K.CTRL)) {
								var step = K.isDown(K.SHIFT) ? 0.5 : 1.0;
								x = Math.round(x / step) * step;
							}
							return x;
						}
						var s = newMat.getScale();
						sceneObj.scaleX = quantize(scaleSnap(s.x), scaleQuant);
						sceneObj.scaleY = quantize(scaleSnap(s.y), scaleQuant);
						sceneObj.scaleZ = quantize(scaleSnap(s.z), scaleQuant);
					}	

					prefab.updateInstance(ctx);	
				}

				gizmo.onFinishMove = function() {
					//var newState = [for(o in objects3d) o.saveTransform()];
					/*undo.change(Custom(function(undo) {
						if( undo ) {
							for(i in 0...objects3d.length) {
								objects3d[i].loadTransform(prevState[i]);
								objects3d[i].applyPos(sceneObjs[i]);
							}
						}
						else {
							for(i in 0...objects3d.length) {
								objects3d[i].loadTransform(newState[i]);
								objects3d[i].applyPos(sceneObjs[i]);
							}
						}
					}));*/
				}/**/
			}
		}
	}

	public function setSelected( ctx : hrt.prefab.Context , b : Bool ) {
		reset();

		if( !editMode )
			return;

		if( b ) {
			@:privateAccess editContext.scene.editor.gizmo.visible = false;
			@:privateAccess editContext.scene.editor.curEdit = null;
			createGizmos(ctx);
			var s2d = @:privateAccess ctx.local2d.getScene();
			interactive = new h2d.Interactive(10000, 10000, s2d);
			interactive.propagateEvents = true;
			interactive.onPush =
				function(e) {
					if( K.isDown( K.MOUSE_LEFT ) && K.isDown( K.CTRL )  ) {
						e.propagate = false;
						var pt = getNewPointPosition(s2d.mouseX, s2d.mouseY, ctx, 1);
						addSplinePoint(pt, ctx);
						showViewers(ctx);
						createGizmos(ctx);
					}
				};

			interactive.onMove =
				function(e) {
					if( K.isDown( K.CTRL ) ) {
						if( newSplinePointViewer == null ) 
							newSplinePointViewer = new NewSplinePointViewer(ctx.local3d.getScene());
						newSplinePointViewer.visible = true;

						var npt = getNewPointPosition(s2d.mouseX, s2d.mouseY, ctx, 1);
						newSplinePointViewer.update(npt);
					}
					else {
						if( newSplinePointViewer != null ) 
							newSplinePointViewer.visible = false;
					}
						
				};
		}
		else {
			editMode = false;
		}
	}

	public function edit( ctx : EditContext ) {

		var props = new hide.Element('
		<div class="spline-editor">
			<div class="group" name="Description">
				<div class="description">
					<i>Ctrl + Left Click</i> Add a point on the spline
					<i>Shift + Left Click</i> Delete a point from the spline
				</div>
			</div>
			<div class="group" name="Tool">
				<div align="center">
					<input type="button" value="Edit Mode : Disabled" class="editModeButton" />
				</div>
			</div>
		</div>');

		var editModeButton = props.find(".editModeButton");
		editModeButton.click(function(_) {
			editMode = !editMode;
			editModeButton.val(editMode ? "Edit Mode : Enabled" : "Edit Mode : Disabled");
			editModeButton.toggleClass("editModeEnabled", editMode);
			setSelected(getContext(), true);
			ctx.onChange(prefab, null);
		});

		ctx.properties.add(props, this, function(pname) {
			ctx.onChange(prefab, pname);
		});

		return props;
	}

}

#end