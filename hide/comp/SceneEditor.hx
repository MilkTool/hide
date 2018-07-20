package hide.comp;

import hxd.Key as K;
import hxd.Math as M;

import hide.prefab.Prefab as PrefabElement;
import hide.prefab.Object3D;
import h3d.scene.Object;

@:access(hide.comp.SceneEditor)
class SceneEditorContext extends hide.prefab.EditContext {

	public var editor(default, null) : SceneEditor;
	public var elements : Array<PrefabElement>;
	public var rootObjects(default, null): Array<Object>;
	public var rootElements(default, null): Array<PrefabElement>;

	public function new(ctx, elts, editor) {
		super(ctx);
		this.editor = editor;
		this.updates = editor.updates;
		this.elements = elts;
		rootObjects = [];
		rootElements = [];
		cleanups = [];
		for(elt in elements) {
			// var obj3d = elt.to(Object3D);
			// if(obj3d == null) continue;
			if(!SceneEditor.hasParent(elt, elements)) {
				rootElements.push(elt);
				var ctx = getContext(elt);
				if(ctx != null) {
					var pobj = elt.parent == editor.sceneData ? ctx.shared.root3d : getContext(elt.parent).local3d;
					if( ctx.local3d != pobj )
						rootObjects.push(ctx.local3d);
				}
			}
		}
	}

	override function getCurrentProps( p : hide.prefab.Prefab ) {
		var cur = editor.curEdit;
		return cur != null && cur.elements[0] == p ? editor.properties.element : new Element();
	}

	override function rebuild() {
		properties.clear();
		cleanup();
		if(elements.length > 0) {
			var e = elements[0];
			editor.scene.setCurrent();
			e.edit(this);
			var sheet = e.getCdbModel();
			if( sheet != null ) {
				if( e.props == null ) {
					trace("TODO : add button to init properties");
					return;
				}
				var props = properties.add(new hide.Element('
					<div class="group" name="Properties ${sheet.name.split('@').pop()}">
					</div>
				'),this);
				var editor = new hide.comp.cdb.ObjEditor(sheet, e.props, props.find(".group .content"));
				editor.undo = properties.undo;
				editor.onChange = function(pname) {
					onChange(e, 'props.$pname');
				}
			}
		}
	}

	public function cleanup() {
		for( c in cleanups.copy() )
			c();
		cleanups = [];
	}

	override function onChange(p : PrefabElement, pname: String) {
		super.onChange(p, pname);
		editor.onPrefabChange(p, pname);
	}
}

class SceneEditor {

	public var tree : hide.comp.IconTree<PrefabElement>;
	public var scene : hide.comp.Scene;
	public var properties : hide.comp.PropsEditor;
	public var context(default,null) : hide.prefab.Context;
	public var curEdit(default, null) : SceneEditorContext;
	public var snapToGround = false;
	public var localTransform = true;

	var searchBox : Element;
	var updates : Array<Float -> Void> = [];

	var cameraController : h3d.scene.CameraController;
	var gizmo : hide.view.l3d.Gizmo;
	var interactives : Map<PrefabElement, h3d.scene.Interactive>;
	var ide : hide.Ide;
	var event : hxd.WaitEvent;

	var undo(get, null):hide.ui.UndoHistory;
	function get_undo() { return view.undo; }

	public var view(default, null) : hide.view.FileView;
	var sceneData : PrefabElement;

	public function new(view, data) {
		ide = hide.Ide.inst;
		this.view = view;
		this.sceneData = data;

		event = new hxd.WaitEvent();

		var propsEl = new Element('<div class="props"></div>');
		properties = new hide.comp.PropsEditor(undo,null,propsEl);
		properties.saveDisplayKey = view.saveDisplayKey + "/properties";

		tree = new hide.comp.IconTree();
		tree.async = false;
		tree.autoOpenNodes = false;

		var sceneEl = new Element('<div class="scene"></div>');
		scene = new hide.comp.Scene(view.props, null, sceneEl);
		scene.onReady = onSceneReady;
		scene.onResize = function() {
			context.shared.root2d.x = scene.width >> 1;
			context.shared.root2d.y = scene.height >> 1;
		};

		context = new hide.prefab.Context();
		context.onError = function(e) ide.error(e);
		context.shared = new hide.prefab.ContextShared(scene);
		context.shared.currentPath = view.state.path;
		context.init();

		view.keys.register("copy", onCopy);
		view.keys.register("paste", onPaste);
		view.keys.register("cancel", deselect);
		view.keys.register("selectAll", selectAll);
		view.keys.register("duplicate", duplicate.bind(true));
		view.keys.register("group", groupSelection);
		view.keys.register("delete", () -> deleteElements(curEdit.rootElements));
		view.keys.register("search", function() {
			if(searchBox != null) {
				searchBox.show();
				searchBox.find("input").focus().select();
			}
		});
		view.keys.register("sceneeditor.focus", focusSelection);
		view.keys.register("sceneeditor.lasso", startLassoSelect);
		view.keys.register("sceneeditor.hide", function() {	setVisible(curEdit.elements, false); });
		view.keys.register("sceneeditor.isolate", function() {	isolate(curEdit.elements); });
		view.keys.register("sceneeditor.showAll", function() {	setVisible(context.shared.elements(), true); });
		view.keys.register("sceneeditor.selectParent", function() {
			if(curEdit.rootElements.length > 0)
				selectObjects([curEdit.rootElements[0].parent]);
		});
	}

	public function getSelection() {
		return curEdit != null ? curEdit.elements : [];
	}

	public function addSearchBox(parent : Element) {
		searchBox = new Element("<div>").addClass("searchBox").appendTo(parent);
		new Element("<input type='text'>").appendTo(searchBox).keydown(function(e) {
			if( e.keyCode == 27 ) {
				searchBox.find("i").click();
				return;
			}
		}).keyup(function(e) {
			tree.searchFilter(e.getThis().val());
		});
		new Element("<i>").addClass("fa fa-times-circle").appendTo(searchBox).click(function(_) {
			tree.searchFilter(null);
			searchBox.toggle();
		});
	}

	function makeCamController() {
		var c = new h3d.scene.CameraController(scene.s3d);
		c.friction = 0.9;
		c.panSpeed = 0.6;
		c.zoomAmount = 1.05;
		c.smooth = 0.7;
		return c;
	}

	function focusSelection() {
		if(curEdit.rootObjects.length > 0) {
			cameraController.set(curEdit.rootObjects[0].getAbsPos().getPosition().toPoint());
		}
		for(obj in curEdit.rootElements)
			tree.revealNode(obj);
	}

	function onSceneReady() {

		tree.saveDisplayKey = view.saveDisplayKey + '/tree';

		scene.s2d.addChild(context.shared.root2d);
		scene.s3d.addChild(context.shared.root3d);

		gizmo = new hide.view.l3d.Gizmo(scene);
		gizmo.moveStep = view.props.get("sceneeditor.gridSnapStep");

		cameraController = makeCamController();

		resetCamera();

		var cam = @:privateAccess view.getDisplayState("Camera");
		if( cam != null ) {
			scene.s3d.camera.pos.set(cam.x, cam.y, cam.z);
			scene.s3d.camera.target.set(cam.tx, cam.ty, cam.tz);
		}
		cameraController.loadFromCamera();
		scene.onUpdate = update;

		// BUILD scene tree

		function makeItem(o:PrefabElement) : hide.comp.IconTree.IconTreeItem<PrefabElement> {
			var p = o.getHideProps();
			var r : hide.comp.IconTree.IconTreeItem<PrefabElement> = {
				value : o,
				text : o.name,
				icon : "fa fa-"+p.icon,
				children : o.children.length > 0
			};
			return r;
		}
		tree.get = function(o:PrefabElement) {
			var objs = o == null ? sceneData.children : Lambda.array(o);
			var out = [for( o in objs ) makeItem(o)];
			return out;
		};
		tree.element.parent().contextmenu(function(e) {
			e.preventDefault();
			var current = tree.getCurrentOver();
			if(current != null && (curEdit == null || curEdit.elements.indexOf(current) < 0)) {
				selectObjects([current]);
			}

			var newItems = getNewContextMenu(current);
			var menuItems : Array<hide.comp.ContextMenu.ContextMenuItem> = [
				{ label : "New...", menu : newItems },
			];
			var actionItems : Array<hide.comp.ContextMenu.ContextMenuItem> = [
				{ label : "Rename", enabled : current != null, click : function() tree.editNode(current) },
				{ label : "Delete", enabled : current != null, click : function() deleteElements(curEdit.rootElements) },
				{ label : "Duplicate", enabled : current != null, click : duplicate.bind(false) },
				{ label : "Reference", enabled : current != null, click : function() createRef(current, current.parent) },
			];

			if(current != null && current.to(Object3D) != null) {
				var visible = current.to(Object3D).visible;
				menuItems = menuItems.concat([
					{ label : "Visible", checked : visible, click : function() setVisible(curEdit.elements, !visible) },
					{ label : "Select all", click : selectAll },
					{ label : "Select children", enabled : current != null, click : function() selectObjects(current.flatten()) },
				]);
				actionItems = actionItems.concat([
					{ label : "Isolate", click : function() isolate(curEdit.elements) },
					{ label : "Group", enabled : curEdit != null && canGroupSelection(), click : groupSelection }
				]);
			}
			else if(current != null) {
				var enabled = current.enabled;
				menuItems.push({ label : "Enable", checked : enabled, click : function() setEnabled(curEdit.elements, !enabled) });
			}

			menuItems.push({ isSeparator : true, label : "" });
			new hide.comp.ContextMenu(menuItems.concat(actionItems));
		});
		tree.allowRename = true;
		tree.init();
		tree.onClick = function(e) {
			selectObjects(tree.getSelection(), false);
		}
		tree.onDblClick = function(e) {
			focusSelection();
			return true;
		}
		tree.onRename = function(e, name) {
			var oldName = e.name;
			e.name = name;
			undo.change(Field(e, "name", oldName), function() tree.refresh());
			return true;
		};
		tree.onAllowMove = function(_, _) {
			return true;
		};

		// Batch tree.onMove, which is called for every node moved, causing problems with undo and refresh
		{
			var movetimer : haxe.Timer = null;
			var moved = [];
			tree.onMove = function(e, to, idx) {
				if(movetimer != null) {
					movetimer.stop();
				}
				moved.push(e);
				movetimer = haxe.Timer.delay(function() {
					reparentElement(moved, to, idx);
					movetimer = null;
					moved = [];
				}, 50);
			}
		}
		tree.applyStyle = updateTreeStyle;
		selectObjects([]);
		refresh();
	}

	public function refresh( ?callb ) {
		var sh = context.shared;
		refreshScene();
		tree.refresh(function() {
			var all = sceneData.flatten(hxd.prefab.Prefab);
			for(elt in all) {
				var el = tree.getElement(elt);
				if(el == null) continue;
				updateTreeStyle(elt, el);
			}
			if(callb != null) callb();
		});
	}

	function refreshProps() {
		selectObjects(curEdit.elements, false);
	}

	public function refreshScene() {
		var sh = context.shared;
		sh.root3d.remove();
		sh.root2d.remove();
		for( f in sh.cleanups )
			f();
		sh.root3d = new h3d.scene.Object();
		scene.s3d.addChild(sh.root3d);
		sh.root2d = new h2d.Sprite();
		scene.s2d.addChild(sh.root2d);
		scene.onResize();
		sh.cleanups = [];
		context.init();
		sceneData.makeInstance(context);
		var bgcol = scene.engine.backgroundColor;
		scene.init();
		scene.engine.backgroundColor = bgcol;
		refreshInteractives();
	}

	function refreshInteractives() {
		var contexts = context.shared.contexts;
		interactives = new Map();
		var all = contexts.keys();
		for(elt in all) {
			if(elt.to(Object3D) == null)
				continue;
			var ctx = contexts[elt];
			var o = ctx.local3d;
			if(o == null)
				continue;
			var meshes = context.shared.getObjects(elt, h3d.scene.Mesh);
			var invRootMat = o.getAbsPos().clone();
			invRootMat.invert();
			var bounds = new h3d.col.Bounds();
			for(mesh in meshes) {
				if(mesh.ignoreCollide)
					continue;
				var localMat = mesh.getAbsPos().clone();
				localMat.multiply(localMat, invRootMat);
				var lb = mesh.primitive.getBounds().clone();
				lb.transform(localMat);
				bounds.add(lb);
			}
			var meshCollider = new h3d.col.Collider.GroupCollider([for(m in meshes) {
				var c : h3d.col.Collider = try m.getGlobalCollider() catch(e: Dynamic) null;
				if(c != null) c;
			}]);
			var boundsCollider = new h3d.col.ObjectCollider(o, bounds);
			var int = new h3d.scene.Interactive(boundsCollider, o);
			interactives.set(elt, int);
			int.ignoreParentTransform = true;
			int.preciseShape = meshCollider;
			int.propagateEvents = true;
			var startDrag = null;
			int.onPush = function(e) {
				startDrag = [scene.s2d.mouseX, scene.s2d.mouseY];
				e.propagate = false;
				var elts = null;
				if(K.isDown(K.SHIFT)) {
					if(Type.getClass(elt.parent) == hide.prefab.Object3D)
						elts = [elt.parent];
					else
						elts = elt.parent.children;
				}
				else
					elts = [elt];

				if(K.isDown(K.CTRL)) {
					var current = curEdit.elements.copy();
					if(current.indexOf(elt) < 0) {
						for(e in elts) {
							if(current.indexOf(e) < 0)
								current.push(e);
						}
					}
					else {
						for(e in elts)
							current.remove(e);
					}
					selectObjects(current);
				}
				else
					selectObjects(elts);
			}
			int.onRelease = function(e) {
				startDrag = null;
			}
			int.onMove = function(e) {
				if(startDrag != null) {
					if((M.abs(startDrag[0] - scene.s2d.mouseX) + M.abs(startDrag[1] - scene.s2d.mouseY)) > 5) {
						startDrag = null;
						moveGizmoToSelection();
						gizmo.startMove(MoveXY);
					}
				}
			}
		}
	}

	function setupGizmo() {
		if(curEdit == null) return;
		gizmo.onStartMove = function(mode) {
			var objects3d = [for(o in curEdit.rootElements) {
				var obj3d = o.to(hide.prefab.Object3D);
				if(obj3d != null)
					obj3d;
			}];
			var sceneObjs = [for(o in objects3d) getContext(o).local3d];
			var pivotPt = getPivot(sceneObjs);
			var pivot = new h3d.Matrix();
			pivot.initTranslation(pivotPt.x, pivotPt.y, pivotPt.z);
			var invPivot = pivot.clone();
			invPivot.invert();

			var localMats = [for(o in sceneObjs) {
				var m = worldMat(o);
				m.multiply(m, invPivot);
				m;
			}];

			var posQuant = view.props.get("sceneeditor.xyzPrecision");
			var scaleQuant = view.props.get("sceneeditor.scalePrecision");
			var rotQuant = view.props.get("sceneeditor.rotatePrecision");

			inline function quantize(x: Float, step: Float) {
				if(step > 0) {
					x = Math.round(x / step) * step;
					x = untyped parseFloat(x.toFixed(5)); // Snap to closest nicely displayed float :cold_sweat:
				}
				return x;
			}

			var prevState = [for(o in objects3d) o.save()];
			gizmo.onMove = function(translate: h3d.Vector, rot: h3d.Quat, scale: h3d.Vector) {
				var transf = new h3d.Matrix();
				transf.identity();
				if(rot != null)
					rot.toMatrix(transf);
				if(translate != null)
					transf.translate(translate.x, translate.y, translate.z);
				for(i in 0...sceneObjs.length) {
					var newMat = localMats[i].clone();
					newMat.multiply(newMat, transf);
					newMat.multiply(newMat, pivot);
					if(snapToGround && mode == MoveXY) {
						newMat.tz = getZ(newMat.tx, newMat.ty);
					}
					var invParent = sceneObjs[i].parent.getAbsPos().clone();
					invParent.invert();
					newMat.multiply(newMat, invParent);
					if(scale != null) {
						newMat.prependScale(scale.x, scale.y, scale.z);
					}
					var obj3d = objects3d[i];
					var rot = newMat.getEulerAngles();
					obj3d.x = quantize(newMat.tx, posQuant);
					obj3d.y = quantize(newMat.ty, posQuant);
					obj3d.z = quantize(newMat.tz, posQuant);
					obj3d.rotationX = quantize(M.radToDeg(rot.x), rotQuant);
					obj3d.rotationY = quantize(M.radToDeg(rot.y), rotQuant);
					obj3d.rotationZ = quantize(M.radToDeg(rot.z), rotQuant);
					if(scale != null) {
						var s = newMat.getScale();
						obj3d.scaleX = quantize(s.x, scaleQuant);
						obj3d.scaleY = quantize(s.y, scaleQuant);
						obj3d.scaleZ = quantize(s.z, scaleQuant);
					}
					obj3d.applyPos(sceneObjs[i]);
				}
			}

			gizmo.onFinishMove = function() {
				var newState = [for(o in objects3d) o.save()];
				refreshProps();
				undo.change(Custom(function(undo) {
					if( undo ) {
						for(i in 0...objects3d.length) {
							objects3d[i].load(prevState[i]);
							objects3d[i].applyPos(sceneObjs[i]);
						}
						refreshProps();
					}
					else {
						for(i in 0...objects3d.length) {
							objects3d[i].load(newState[i]);
							objects3d[i].applyPos(sceneObjs[i]);
						}
						refreshProps();
					}
				}));
			}
		}
	}

	function moveGizmoToSelection() {
		// Snap Gizmo at center of objects
		gizmo.getRotationQuat().identity();
		if(curEdit != null && curEdit.rootObjects.length > 0) {
			var pos = getPivot(curEdit.rootObjects);
			gizmo.visible = true;
			gizmo.setPosition(pos.x, pos.y, pos.z);

			if(curEdit.rootObjects.length == 1 && (localTransform || K.isDown(K.ALT))) {
				var obj = curEdit.rootObjects[0];
				var mat = worldMat(obj);
				var s = mat.getScale();
				mat.prependScale(1.0 / s.x, 1.0 / s.y, 1.0 / s.z);
				gizmo.getRotationQuat().initRotateMatrix(mat);
			}
		}
		else {
			gizmo.visible = false;
		}
	}

	var inLassoMode = false;
	function startLassoSelect() {
		if(inLassoMode) {
			inLassoMode = false;
			return;
		}
		inLassoMode = true;
		var g = new h2d.Sprite(scene.s2d);
		var overlay = new h2d.Bitmap(h2d.Tile.fromColor(0xffffff, 10000, 10000, 0.1), g);
		var intOverlay = new h2d.Interactive(10000, 10000, scene.s2d);
		var lastPt = new h2d.col.Point(scene.s2d.mouseX, scene.s2d.mouseY);
		var points : h2d.col.Polygon = [lastPt];
		var polyG = new h2d.Graphics(g);
		event.waitUntil(function(dt) {
			var curPt = new h2d.col.Point(scene.s2d.mouseX, scene.s2d.mouseY);
			if(curPt.distance(lastPt) > 3.0) {
				points.push(curPt);
				polyG.clear();
				polyG.beginFill(0xff0000, 0.5);
				polyG.lineStyle(1.0, 0, 1.0);
				polyG.moveTo(points[0].x, points[0].y);
				for(i in 1...points.length) {
					polyG.lineTo(points[i].x, points[i].y);
				}
				polyG.endFill();
				lastPt = curPt;
			}

			var finish = false;
			if(!inLassoMode || K.isPressed(K.ESCAPE)) {
				finish = true;
			}

			if(K.isReleased(K.MOUSE_LEFT) || K.isPressed(K.MOUSE_LEFT)) {
				var contexts = context.shared.contexts;
				var all = getAllSelectable();
				var inside = [];
				for(elt in all) {
					if(elt.to(Object3D) == null)
						continue;
					var ctx = contexts[elt];
					var o = ctx.local3d;
					if(o == null || !o.visible)
						continue;
					var absPos = o.getAbsPos();
					var screenPos = worldToScreen(absPos.tx, absPos.ty, absPos.tz);
					if(points.contains(screenPos, false)) {
						inside.push(elt);
					}
				}
				selectObjects(inside);
				finish = true;
			}

			if(finish) {
				intOverlay.remove();
				g.remove();
				inLassoMode = false;
				return true;
			}
			return false;
		});
	}

	public function onPrefabChange(p: PrefabElement, ?pname: String) {
		var model = p.to(hide.prefab.Model);
		if(model != null && pname == "source") {
			refreshScene();
			return;
		}

		if(p != sceneData) {
			var el = tree.getElement(p);
			updateTreeStyle(p, el);
		}
	}

	function updateTreeStyle(p: PrefabElement, el: Element) {
		var obj3d  = p.to(Object3D);
		if(obj3d != null)
			el.toggleClass("invisible", !obj3d.visible);
		el.toggleClass("disabled", !p.enabled);
	}

	public function getContext(elt : PrefabElement) {
		if(elt != null) {
			return context.shared.contexts.get(elt);
		}
		return null;
	}

	public function getObject(elt: PrefabElement) {
		var ctx = getContext(elt);
		if(ctx != null)
			return ctx.local3d;
		return context.shared.root3d;
	}

	public function addObject( e : PrefabElement ) {
		var roots = e.parent.children;
		undo.change(Custom(function(undo) {
			if( undo )
				roots.remove(e);
			else
				roots.push(e);
			refresh();
		}));
		refresh(function() {
			selectObjects([e]);
		});
		if( e.parent == sceneData && sceneData.children.length == 1 )
			resetCamera();
	}

	public function selectObjects( elts : Array<PrefabElement>, ?includeTree=true) {
		if( curEdit != null )
			curEdit.cleanup();
		var edit = makeEditContext(elts);
		edit.rebuild();

		if(includeTree) {
			tree.setSelection(elts);
		}

		var map = new Map<PrefabElement,Bool>();
		function selectRec(e : PrefabElement, b:Bool) {
			if( map.exists(e) )
				return;
			map.set(e, true);
			e.setSelected(context, b);
			for( e in e.children )
				selectRec(e,b);
		}

		for( e in elts )
			selectRec(e, true);

		edit.cleanups.push(function() {
			for( e in map.keys() )
				e.setSelected(context, false);
		});

		curEdit = edit;
		setupGizmo();
	}

	public function resetCamera(?top = false) {
		var targetPt = new h3d.col.Point(0, 0, 0);
		if(curEdit != null && curEdit.rootObjects.length > 0) {
			targetPt = curEdit.rootObjects[0].getAbsPos().getPosition().toPoint();
		}
		if(top)
			cameraController.set(200, Math.PI/2, 0.001, targetPt);
		else
			cameraController.set(200, -4.7, 0.8, targetPt);
		cameraController.toTarget();
	}

	public function getPickTransform(parent: PrefabElement) {
		var proj = screenToWorld(scene.s2d.mouseX, scene.s2d.mouseY);
		if(proj == null) return null;

		var localMat = new h3d.Matrix();
		localMat.initTranslation(proj.x, proj.y, proj.z);

		if(parent == null)
			return localMat;

		var parentMat = worldMat(getObject(parent));
		parentMat.invert();

		localMat.multiply(localMat, parentMat);
		return localMat;
	}

	public function dropModels(paths: Array<String>, parent: PrefabElement) {
		var localMat = getPickTransform(parent);
		if(localMat == null) return;

		var models: Array<PrefabElement> = [];
		for(path in paths) {
			var model = new hide.prefab.Model(parent);
			model.setTransform(localMat);
			var relative = ide.makeRelative(path);
			model.source = relative;
			autoName(model);
			models.push(model);
		}
		refresh(() -> selectObjects(models));
	}

	function canGroupSelection() {
		var elts = curEdit.rootElements;
		if(elts.length == 0)
			return false;

		if(elts.length == 1)
			return true;

		// Only allow grouping of sibling elements
		var parent = elts[0].parent;
		for(e in elts)
			if(e.parent != parent)
				return false;

		return true;
	}

	function groupSelection() {
		if(!canGroupSelection())
			return;

		var elts = curEdit.rootElements;
		var parent = elts[0].parent;
		var parentMat = getObject(parent).getAbsPos();
		var invParentMat = parentMat.clone();
		invParentMat.invert();

		var pivot = getPivot(curEdit.rootObjects);
		var local = new h3d.Matrix();
		local.initTranslation(pivot.x, pivot.y, pivot.z);
		local.multiply(local, invParentMat);
		var group = new hide.prefab.Object3D(parent);
		@:privateAccess group.type = "object";
		autoName(group);
		group.x = local.tx;
		group.y = local.ty;
		group.z = local.tz;
		var parentCtx = getContext(parent);
		if(parentCtx == null)
			parentCtx = context;
		group.makeInstance(parentCtx);
		var groupCtx = getContext(group);

		var reparentUndo = reparentImpl(elts, group, 0);
		undo.change(Custom(function(undo) {
			if(undo) {
				group.parent = null;
				context.shared.contexts.remove(group);
				reparentUndo(true);
			}
			else {
				group.parent = parent;
				context.shared.contexts.set(group, groupCtx);
				reparentUndo(false);
			}
			if(undo)
				refresh(deselect);
			else
				refresh(()->selectObjects([group]));
		}));
		refresh(() -> selectObjects([group]));
	}

	function onCopy() {
		if(curEdit == null) return;
		if(curEdit.rootElements.length == 1) {
			view.setClipboard(curEdit.rootElements[0].saveRec(), "prefab");
		}
		else {
			var lib = new hxd.prefab.Library();
			for(e in curEdit.rootElements) {
				lib.children.push(e);
			}
			view.setClipboard(lib.saveRec(), "library");
		}
	}

	function onPaste() {
		var parent : PrefabElement = sceneData;
		if(curEdit != null && curEdit.elements.length > 0) {
			parent = curEdit.elements[0];
		}
		var obj: PrefabElement = view.getClipboard("prefab");
		if(obj != null) {
			var p = hide.prefab.Prefab.loadRec(obj, parent);
			autoName(p);
			refresh();
		}
		else {
			obj = view.getClipboard("library");
			if(obj != null) {
				var lib = hide.prefab.Prefab.loadRec(obj);
				for(c in lib.children) {
					autoName(c);
					c.parent = parent;
				}
				refresh();
			}
		}
	}

	public function isVisible(elt: PrefabElement) {
		if(elt == sceneData)
			return true;
		var o = elt.to(Object3D);
		if(o == null)
			return true;
		return o.visible && (elt.parent != null ? isVisible(elt.parent) : true);
	}

	public function getAllSelectable() : Array<PrefabElement> {
		var ret = [];
		for(elt in interactives.keys()) {
			var i = interactives.get(elt);
			var p : h3d.scene.Object = i;
			while( p != null && p.visible )
				p = p.parent;
			if( p != null ) continue;
			ret.push(elt);
		}
		return ret;
	}

	public function selectAll() {
		selectObjects(getAllSelectable());
	}

	public function deselect() {
		selectObjects([]);
	}

	public function setEnabled(elements : Array<PrefabElement>, enable: Bool) {
		elements = [for(e in elements) if(e.to(Object3D) == null) e]; // Don't disable/enable Object3Ds, too confusing with visibility
		var old = [for(e in elements) e.enabled];
		function apply(on) {
			for(i in 0...elements.length) {
				elements[i].enabled = on ? enable : old[i];
				onPrefabChange(elements[i]);
			}
			refreshScene();
		}
		apply(true);
		undo.change(Custom(function(undo) {
			if(undo)
				apply(false);
			else
				apply(true);
		}));
	}

	public function setVisible(elements : Array<PrefabElement>, visible: Bool) {
		var obj3ds = [];
		for(e in elements) {
			var o = e.to(Object3D);
			if(o != null) {
				obj3ds.push({o: o, vis: o.visible});
			}
		}

		function apply(b) {
			for(c in obj3ds) {
				c.o.visible = b ? visible : c.vis;
				var obj = getContext(c.o).local3d;
				if(obj != null) {
					c.o.applyPos(obj);
				}
				onPrefabChange(c.o);
			}
		}

		apply(true);
		undo.change(Custom(function(undo) {
			if(undo)
				apply(false);
			else
				apply(true);
		}));
	}

	function isolate(elts : Array<PrefabElement>) {
		var toShow = elts.copy();
		var toHide = [];
		function hideSiblings(elt: PrefabElement) {
			var p = elt.parent;
			for(c in p.children) {
				var needsVisible = c == elt
					|| toShow.indexOf(c) >= 0
					|| hasChild(c, toShow);
				if(!needsVisible) {
					toHide.push(c);
				}
			}
			if(p != sceneData) {
				hideSiblings(p);
			}
		}
		for(e in toShow) {
			hideSiblings(e);
		}
		setVisible(toHide, false);
	}

	function createRef(elt: PrefabElement, toParent: PrefabElement) {
		var ref = new hide.prefab.Reference(toParent);
		ref.name = elt.name;
		ref.refpath = elt.getAbsPath();
		addObject(ref);
	}

	function duplicate(thenMove: Bool) {
		if(curEdit == null) return;
		var elements = curEdit.rootElements;
		if(elements == null || elements.length == 0)
			return;
		var contexts = context.shared.contexts;
		var oldContexts = contexts.copy();
		var newElements = [for(elt in elements) {
			var clone = hide.prefab.Prefab.loadRec(elt.saveRec());
			var index = elt.parent.children.indexOf(elt);
			clone.parent = elt.parent;
			autoName(clone);
			elt.parent.children.remove(clone);
			elt.parent.children.insert(index+1, clone);
			{ elt: clone, idx: index };
		}];
		var newContexts = contexts.copy();
		refresh(function() {
			var all = [for(e in newElements) e.elt];
			selectObjects(all);
			tree.setSelection(all);
			if(thenMove) {
				/* Disabled for now as getPickTransform() will necessarily project on ground, which we don't always want
				if(all.length == 1) {
					var pickMat = getPickTransform(all[0].parent);
					if(pickMat != null) {
						setTransform(all[0], pickMat.getPosition());
						moveGizmoToSelection();
					}
				} */
				gizmo.startMove(MoveXY, true);
				gizmo.onFinishMove = function() {
					refreshProps();
					undo.change(Custom(function(undo) {
						for(e in newElements) {
							if(undo) {
								e.elt.parent.children.remove(e.elt);
							}
							else {
								e.elt.parent.children.insert(e.idx, e.elt);
							}
						}
						if(undo)
							context.shared.contexts = oldContexts;
						else
							context.shared.contexts = newContexts;
						refresh();
						deselect();
					}));
				}
			}
		});
	}

	function setTransform(elt: PrefabElement, ?mat: h3d.Matrix, ?position: h3d.Vector) {
		var obj3d = Std.instance(elt, hide.prefab.Object3D);
		if(obj3d == null)
			return;
		if(mat != null)
			obj3d.setTransform(mat);
		else {
			obj3d.x = position.x;
			obj3d.y = position.y;
			obj3d.z = position.z;
		}
		var o = getContext(obj3d).local3d;
		if(o != null)
			obj3d.applyPos(o);
	}

	function deleteElements(elts : Array<PrefabElement>) {
		var contexts = context.shared.contexts;
		var list = [for(e in elts) {
			elt: e,
			parent: e.parent,
			index: e.parent.children.indexOf(e)
		}];
		var oldContexts = contexts.copy();
		for(e in elts) {
			for(c in e.flatten())
				contexts.remove(c);
		}
		var newContexts = contexts.copy();
		function action(undo) {
			if( undo ) {
				for(o in list)
					o.parent.children.insert(o.index, o.elt);
				context.shared.contexts = oldContexts;
			}
			else {
				for(o in list)
					o.parent.children.remove(o.elt);
				context.shared.contexts = newContexts;
			}
			deselect();
			refresh();
		}
		action(false);
		undo.change(Custom(action));
	}

	function reparentElement(e : Array<PrefabElement>, to : PrefabElement, index : Int) {
		if( to == null )
			to = sceneData;

		var undoFunc = reparentImpl(e, to, index);
		undo.change(Custom(function(undo) {
			undoFunc(undo);
			refresh();
		}));
		refresh();
	}

	function reparentImpl(elts : Array<PrefabElement>, to: PrefabElement, index: Int) {
		var undoes = [];
		for(e in elts) {
			var prev = e.parent;
			var prevIndex = prev.children.indexOf(e);
			e.parent = to;
			to.children.remove(e);
			to.children.insert(index, e);

			var obj3d = e.to(Object3D);
			var toObj = getObject(to);
			var obj = getObject(e);
			var prevState = null, newState = null;
			if(obj3d != null && toObj != null && obj != null) {
				var mat = worldMat(obj);
				var parentMat = worldMat(toObj);
				parentMat.invert();
				mat.multiply(mat, parentMat);
				prevState = obj3d.save();
				obj3d.setTransform(mat);
				newState = obj3d.save();
			}

			undoes.push(function(undo) {
				if( undo ) {
					e.parent = prev;
					prev.children.remove(e);
					prev.children.insert(prevIndex, e);
					if(obj3d != null)
						obj3d.load(prevState);
				} else {
					e.parent = to;
					to.children.remove(e);
					to.children.insert(index, e);
					if(obj3d != null)
						obj3d.load(newState);
				};
			});
		}
		return function(undo) {
			for(f in undoes) {
				f(undo);
			}
		}
	}

	function autoName(p : PrefabElement) {

		var uniqueName = false;
		var layer = p.getParent(hide.prefab.l3d.Layer);
		if(layer != null) {
			uniqueName = layer.uniqueNames;
		}
		if( p.type == "volumetricLightmap" )
			uniqueName = true;

		var prefix = null;
		if(p.name != null && p.name.length > 0) {
			if(uniqueName)
				prefix = ~/_+[0-9]+$/.replace(p.name, "");
			else
				prefix = p.name;
		}
		else
			prefix = p.getDefaultName();

		if(uniqueName) {
			prefix += "_";
			var id = 0;
			while( sceneData.getPrefabByName(prefix + id) != null )
				id++;

			p.name = prefix + id;
		}
		else
			p.name = prefix;

		for(c in p.children) {
			autoName(c);
		}
	}

	function update(dt:Float) {
		var cam = scene.s3d.camera;
		@:privateAccess view.saveDisplayState("Camera", { x : cam.pos.x, y : cam.pos.y, z : cam.pos.z, tx : cam.target.x, ty : cam.target.y, tz : cam.target.z });
		if(gizmo != null) {
			if(!gizmo.moving) {
				moveGizmoToSelection();
			}
			gizmo.update(dt);
		}
		event.update(dt);
		for( f in updates )
			f(dt);
	}

	// Override
	function makeEditContext(elts : Array<PrefabElement>) : SceneEditorContext {
		var edit = new SceneEditorContext(context, elts, this);
		edit.prefabPath = view.state.path;
		edit.properties = properties;
		edit.scene = scene;
		return edit;
	}

	// Override
	function getNewContextMenu(current: PrefabElement) : Array<hide.comp.ContextMenu.ContextMenuItem> {
		var newItems = new Array<hide.comp.ContextMenu.ContextMenuItem>();
		var allRegs = hxd.prefab.Library.getRegistered();
		var parent = current == null ? sceneData : current;
		var allowChildren = null;
		{
			var cur = parent;
			while( allowChildren == null && cur != null ) {
				allowChildren = cur.getHideProps().allowChildren;
				cur = cur.parent;
			}
		}
		for( ptype in allRegs.keys() ) {
			var pinf = allRegs.get(ptype);
			if( allowChildren != null && !allowChildren(ptype) ) {
				if( pinf.inf.allowParent == null || !pinf.inf.allowParent(parent) )
					continue;
			} else {
				if( pinf.inf.allowParent != null && !pinf.inf.allowParent(parent) )
					continue;
			}
			newItems.push(getNewTypeMenuItem(ptype, parent));
		}
		newItems.sort(function(l1,l2) return Reflect.compare(l1.label,l2.label));
		return newItems;
	}

	function getNewTypeMenuItem(ptype: String, parent: PrefabElement) : hide.comp.ContextMenu.ContextMenuItem {
		var pmodel = hxd.prefab.Library.getRegistered().get(ptype);
		return {
			label : pmodel.inf.name,
			click : function() {
				function make(?path) {
					var p = Type.createInstance(pmodel.cl, [parent]);
					@:privateAccess p.type = ptype;
					if(path != null)
						p.source = path;
					autoName(p);
					return p;
				}

				if( pmodel.inf.fileSource != null )
					ide.chooseFile(pmodel.inf.fileSource, function(path) {
						if( path == null ) return;
						var p = make(path);
						addObject(p);
					});
				else
					addObject(make());
			}
		};
	}

	public function getZ(x: Float, y: Float) {
		var offset = 1000;
		var ray = h3d.col.Ray.fromValues(x, y, offset, 0, 0, -1);
		var dist = projectToGround(ray);
		if(dist >= 0) {
			return offset - dist;
		}
		return 0.;
	}

	public function projectToGround(ray: h3d.col.Ray) {
		var minDist = -1.;
		var zPlane = h3d.col.Plane.Z(0);
		var pt = ray.intersect(zPlane);
		if(pt != null) {
			minDist = pt.sub(ray.getPos()).length();
		}
		return minDist;
	}

	public function screenToWorld(sx: Float, sy: Float) {
		var camera = scene.s3d.camera;
		var ray = camera.rayFromScreen(sx, sy);
		var dist = projectToGround(ray);
		if(dist >= 0) {
			return ray.getPoint(dist);
		}
		return null;
	}

	public function worldToScreen(wx: Float, wy: Float, wz: Float) {
		var camera = scene.s3d.camera;
		var pt = camera.project(wx, wy, wz, scene.s2d.width, scene.s2d.height);
		return new h2d.col.Point(pt.x, pt.y);
	}

	public function worldMat(obj: Object) {
		if(obj.defaultTransform != null) {
			var m = obj.defaultTransform.clone();
			m.invert();
			m.multiply(m, obj.getAbsPos());
			return m;
		}
		else {
			return obj.getAbsPos().clone();
		}
	}

	static function getPivot(objects: Array<Object>) {
		var pos = new h3d.Vector();
		for(o in objects) {
			pos = pos.add(o.getAbsPos().getPosition());
		}
		pos.scale3(1.0 / objects.length);
		return pos;
	}

	public static function hasParent(elt: PrefabElement, list: Array<PrefabElement>) {
		for(p in list) {
			if(isParent(elt, p))
				return true;
		}
		return false;
	}

	public static function hasChild(elt: PrefabElement, list: Array<PrefabElement>) {
		for(p in list) {
			if(isParent(p, elt))
				return true;
		}
		return false;
	}

	public static function isParent(elt: PrefabElement, parent: PrefabElement) {
		var p = elt.parent;
		while(p != null) {
			if(p == parent) return true;
			p = p.parent;
		}
		return false;
	}
}