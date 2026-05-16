#include "femm_c.h"

#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits.h>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

struct LuaTest {
    femm_lua_session_t* lua = nullptr;
    femm_doc_t* doc = nullptr;
    femm_result_t* result = nullptr;
    std::string path;
    int passed = 0;

    LuaTest() {
        if (femm_lua_session_new(&lua) != FEMM_OK) fail_now("femm_lua_session_new");
        if (femm_doc_new(FEMM_PHYSICS_MAGNETICS, &doc) != FEMM_OK) fail_now("femm_doc_new");
        set_active();
    }

    ~LuaTest() {
        if (result) femm_result_free(result);
        if (doc) femm_doc_free(doc);
        if (lua) femm_lua_session_free(lua);
    }

    [[noreturn]] void fail_now(const std::string& label) {
        std::cerr << label << ": " << femm_last_error_message() << "\n";
        std::exit(1);
    }

    void set_active() {
        if (path.empty()) femm_lua_session_set_active(lua, doc, result, nullptr);
        else femm_lua_session_set_active(lua, doc, result, path.c_str());
    }

    void absorb() {
        femm_doc_t* new_doc = nullptr;
        femm_physics_t physics = FEMM_PHYSICS_MAGNETICS;
        const char* new_path = nullptr;
        if (femm_lua_take_replacement_doc(lua, &new_doc, &physics, &new_path) && new_doc) {
            if (result) { femm_result_free(result); result = nullptr; }
            if (doc) femm_doc_free(doc);
            doc = new_doc;
            path = new_path ? new_path : "";
        }

        femm_result_t* new_result = nullptr;
        const char* result_path = nullptr;
        if (femm_lua_take_replacement_result(lua, &new_result, &result_path) && new_result) {
            if (result) femm_result_free(result);
            result = new_result;
        }
        set_active();
    }

    void ok(const std::string& label, const std::string& code) {
        set_active();
        femm_status_t st = femm_lua_eval(lua, code.c_str());
        absorb();
        if (st != FEMM_OK) {
            std::cerr << "Lua command failed [" << label << "]\n"
                      << code << "\n"
                      << femm_lua_error(lua) << "\n";
            std::exit(1);
        }
        ++passed;
    }

    void lua_error_contains(const std::string& label, const std::string& code, const std::string& needle) {
        set_active();
        femm_status_t st = femm_lua_eval(lua, code.c_str());
        absorb();
        if (st != FEMM_ERR_LUA || std::string(femm_lua_error(lua)).find(needle) == std::string::npos) {
            std::cerr << "Lua command did not fail as expected [" << label << "]\n"
                      << code << "\n"
                      << "error: " << femm_lua_error(lua) << "\n";
            std::exit(1);
        }
        ++passed;
    }
};

bool has_command(const std::string& name) {
    for (size_t i = 0; i < femm_lua_num_commands(); ++i) {
        const char* n = femm_lua_command_name(i);
        if (n && name == n) return true;
    }
    return false;
}

std::string call(const std::string& name, const std::string& args = "") {
    return name + "(" + args + ")";
}

void run_many(LuaTest& t, const std::string& label, const std::vector<std::string>& names,
              const std::string& args = "") {
    for (const auto& name : names) t.ok(label + ":" + name, call(name, args));
}

std::string path_for(const std::string& name) {
    (void)std::system("mkdir -p build/lua_test");
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) return "build/lua_test/" + name;
    return std::string(cwd) + "/build/lua_test/" + name;
}

void test_registry() {
    const char* expected[] = {
        "open", "newdocument", "new_document", "mi_addnode", "mi_add_node",
        "mi_analyze", "mi_analyse", "mi_savebitmap", "ei_addconductorprop",
        "hi_addtkpoint", "ci_readdxf", "mo_getpointvalues", "mo_gapintegral",
        "eo_getconductorproperties", "ho_lineintegral", "co_blockintegral",
        "clearconsole", "show_console", "mlopen"
    };
    for (const char* name : expected) {
        if (!has_command(name)) {
            std::cerr << "missing Lua command: " << name << "\n";
            std::exit(1);
        }
    }
}

void test_globals(LuaTest& t) {
    t.ok("print/complex", "print(1, 2, Complex(3,4))");
    std::string output = femm_lua_output(t.lua);
    if (output.find("--> 1") == std::string::npos || output.find("\t2") == std::string::npos) {
        std::cerr << "unexpected Lua console output: " << output << "\n";
        std::exit(1);
    }
    run_many(t, "console", {"showconsole", "show_console", "hideconsole", "hide_console"});
    t.ok("clearconsole", "clearconsole(); print('after clear')");
    t.ok("clear_console", "clear_console(); print('after clear 2')");
    run_many(t, "global noops", {"pause", "showpointprops", "show_point_props",
                                 "hidepointprops", "hide_point_props",
                                 "main_maximize", "main_minimize", "main_resize", "main_restore"});
    t.ok("messagebox", "messagebox('hello')");
    t.ok("setcompatibilitymode", "setcompatibilitymode(1)");
    t.ok("setcurrentdirectory", "setcurrentdirectory('build/lua_test')");
    t.ok("chdir", "chdir('..')");
    t.ok("new_document", "new_document(0)");
    t.ok("create", "create(0)");
    t.lua_error_contains("prompt", "prompt('x')", "prompt is not supported");
    t.lua_error_contains("quit", "quit()", "quit is not supported");
    t.lua_error_contains("exit", "exit()", "quit is not supported");
}

std::string fixture_script(const std::string& p, int physics, const std::string& root, bool include_extra_alias_geometry = true) {
    std::ostringstream s;
    s << "newdocument(" << physics << ")\n";
    if (p == "mi") {
        s << p << "_probdef(0,1,0,1e-8,1,30,0)\n";
        s << p << "_addmaterial('air',1,1,0,0,0,0,0,0,1,0)\n";
        s << p << "_addboundprop('lo',0,0,0,0,0)\n";
        s << p << "_addboundprop('hi',0,0,0,0,0)\n";
    } else if (p == "ei") {
        s << p << "_probdef(1,0,1e-8,1,30)\n";
        s << p << "_addmaterial('air',1,1,0)\n";
        s << p << "_addboundprop('lo',0,0,0,0,0)\n";
        s << p << "_addboundprop('hi',100,0,0,0,0)\n";
    } else if (p == "hi") {
        s << p << "_probdef(1,0,1e-8,1,30)\n";
        s << p << "_addmaterial('iron',50,50,0,0)\n";
        s << p << "_addboundprop('lo',0,300,0,0,0,0,0)\n";
        s << p << "_addboundprop('hi',0,400,0,0,0,0,0)\n";
    } else {
        s << p << "_probdef(1,0,0,1e-8,1,30)\n";
        s << p << "_addmaterial('cu',58,58,1,1,0,0)\n";
        s << p << "_addboundprop('lo',0,0,0,0,0)\n";
        s << p << "_addboundprop('hi',10,0,0,0,0)\n";
    }
    s << p << "_addnode(0,0); " << p << "_add_node(10,0); "
      << p << "_addnode(10,5); " << p << "_add_node(0,5)\n";
    s << p << "_addsegment(0,0,10,0); " << p << "_add_segment(10,0,10,5); "
      << p << "_addsegment(10,5,0,5); " << p << "_add_segment(0,5,0,0)\n";
    if (include_extra_alias_geometry) {
        s << p << "_addarc(10,5,0,5,10,1); " << p << "_add_arc(0,5,0,0,10,1)\n";
        s << p << "_addblocklabel(5,2.5); " << p << "_add_block_label(2,2.5)\n";
    } else {
        s << p << "_addblocklabel(5,2.5)\n";
    }
    s << p << "_selectsegment(5,0); " << p << "_setsegmentprop('lo',-1,0,0,'')\n";
    s << p << "_clear_selected(); " << p << "_select_segment(5,5); "
      << p << "_set_segment_prop('hi',-1,0,0,'')\n";
    s << p << "_clearselected(); " << p << "_selectlabel(5,2.5); "
      << p << "_setblockprop('" << (p == "hi" ? "iron" : (p == "ci" ? "cu" : "air"))
      << "',0,0.5,'',0,3,1)\n";
    if (include_extra_alias_geometry) {
        s << p << "_clearselected(); " << p << "_select_label(2,2.5); "
          << p << "_set_block_prop('" << (p == "hi" ? "iron" : (p == "ci" ? "cu" : "air"))
          << "',0,0.5,'',0,3,1)\n";
    }
    s << p << "_selectgroup(3); " << p << "_setgroup(4); "
      << p << "_select_group(4); " << p << "_set_group(3)\n";
    s << p << "_saveas('" << root << "')\n";
    return s.str();
}

void test_preprocessor_aliases(LuaTest& t, const std::string& p, int physics) {
    const std::string root = path_for("pre_" + p);
    t.ok(p + " newdocument aliases",
         p + "_newdocument(" + std::to_string(physics) + "); " +
         p + "_new_document(" + std::to_string(physics) + ")");
    t.ok(p + " fixture", fixture_script(p, physics, root));

    run_many(t, p + " probdef aliases", {p + "_prob_def"}, p == "mi" ? "0,1,0,1e-8,1,30,0" : "1,0,1e-8,1,30");
    run_many(t, p + " selection", {p + "_selectnode", p + "_select_node"}, "0,0");
    run_many(t, p + " selection", {p + "_selectarcsegment", p + "_select_arcsegment", p + "_select_arc_segment"}, "9,5");
    t.ok(p + " set arc props",
         p + "_setarcsegmentprop(1,'hi',0,1,''); " +
         p + "_set_arc_segment_prop(1,'hi',0,1,''); " +
         p + "_set_arcsegment_prop(1,'hi',0,1,'')");
    run_many(t, p + " selection", {p + "_selectlabel", p + "_select_label"}, "5,2.5");
    run_many(t, p + " edit mode", {p + "_seteditmode", p + "_set_edit_mode"}, "4");
    run_many(t, p + " transforms", {p + "_movetranslate", p + "_move_translate"}, "0.1,0.1");
    run_many(t, p + " transforms", {p + "_moverotate", p + "_move_rotate"}, "0,0,1");
    run_many(t, p + " transforms", {p + "_copytranslate", p + "_copy_translate"}, "0.1,0,1");
    run_many(t, p + " transforms", {p + "_copyrotate", p + "_copy_rotate"}, "0,0,1,1");
    t.ok(p + " mirror", p + "_mirror(0,0,1,0)");
    t.ok(p + " scale", p + "_scale(0,0,1.0)");

    t.ok(p + " add point prop", p + "_addpointprop('pt_a',0,0); " + p + "_add_point_prop('pt_b',0,0)");
    t.ok(p + " set node prop", p + "_selectnode(0,0); " + p + "_setnodeprop('pt_a',1); " + p + "_set_node_prop('pt_b',2)");
    t.ok(p + " delete point props", p + "_deletepointprop('pt_a'); " + p + "_delete_point_prop('pt_b'); "
                                     + p + "_addpointprop('pt_c',0,0); " + p + "_delpointprop('pt_c')");

    t.ok(p + " add/delete material aliases",
         p + "_addmaterial('mat_a',1,1,0,0,0,0,0,0,1,0); " +
         p + "_add_material('mat_b',1,1,0,0,0,0,0,0,1,0); " +
         p + "_addmaterial('mat_c',1,1,0,0,0,0,0,0,1,0); " +
         p + "_deletematerial('mat_a'); " + p + "_delete_material('mat_b'); " +
         p + "_delmaterial('mat_c')");
    t.ok(p + " add/delete boundary aliases",
         p + "_addboundprop('bd_a',0,0,0,0,0); " + p + "_add_bound_prop('bd_b',0,0,0,0,0); " +
         p + "_addboundprop('bd_c',0,0,0,0,0); " +
         p + "_deleteboundprop('bd_a'); " + p + "_delete_bound_prop('bd_b'); " +
         p + "_delboundprop('bd_c')");
    t.ok(p + " add/delete conductor aliases",
         p + "_addconductorprop('cond_a',0,0,0); " + p + "_add_conductor_prop('cond_b',0,0,0); " +
         p + "_deleteconductor('cond_a'); " + p + "_delete_conductor('cond_b')");

    if (p == "mi") {
        t.ok("mi circuit aliases", "mi_addcircprop('coil_a',0,0); mi_add_circ_prop('coil_b',0,0); "
                                "mi_addcircprop('coil_c',0,0); "
                                "mi_deletecircuit('coil_a'); mi_delete_circuit('coil_b'); "
                                "mi_delcircprop('coil_c')");
        t.ok("mi bh aliases", "mi_addmaterial('steel',1,1,0,0,0,0,0,0,1,0); "
                             "mi_addbhpoint('steel',1,100); mi_add_bh_point('steel',1.5,200); "
                             "mi_clearbhpoints('steel'); mi_clear_bh_points('steel')");
    }

    run_many(t, p + " save", {p + "_save", p + "_saveas", p + "_save_as"}, "'" + root + "_again'");
    run_many(t, p + " smartmesh", {p + "_smartmesh", "smartmesh"}, "1");
    run_many(t, p + " view noops",
             {p + "_showgrid", p + "_show_grid", p + "_hidegrid", p + "_hide_grid",
              p + "_showmesh", p + "_show_mesh", p + "_hidemesh", p + "_hide_mesh",
              p + "_refreshview", p + "_refrescview", p + "_refresh_view",
              p + "_zoomnatural", p + "_zoom_natural", p + "_zoomout", p + "_zoom_out",
              p + "_zoomin", p + "_zoom_in", p + "_zoom", p + "_grid_snap", p + "_gridsnap",
              p + "_setgrid", p + "_set_grid", p + "_shownames", p + "_show_names",
              p + "_setfocus", p + "_set_focus", p + "_maximize", p + "_minimize",
              p + "_resize", p + "_restore", p + "_close"}, "1");
    run_many(t, p + " delete selected noops",
             {p + "_deleteselected", p + "_delete_selected", p + "_deleteselectednodes",
              p + "_delete_selected_nodes", p + "_deleteselectedsegments",
              p + "_delete_selected_segments", p + "_deleteselectedarcsegments",
              p + "_delete_selected_arcsegments", p + "_delete_selected_arc_segments",
              p + "_deleteselectedlabels", p + "_delete_selected_labels"});
}

void test_open_roundtrip(LuaTest& t) {
    const std::string root = path_for("open_roundtrip");
    t.ok("saveas for open", "newdocument(0); mi_addnode(0,0); mi_saveas('" + root + "')");
    t.ok("open", "open('" + root + ".fem')");
    if (femm_num_nodes(t.doc) != 1) {
        std::cerr << "open() did not replace active document\n";
        std::exit(1);
    }
}

void test_solve_and_post(LuaTest& t, const std::string& pre, const std::string& post, int physics) {
    const std::string root = path_for("solve_" + pre);
    t.ok(pre + " solve fixture", fixture_script(pre, physics, root, false));
    t.ok(pre + " mesh aliases", pre + "_createmesh(); " + pre + "_create_mesh()");
    t.ok(pre + " analyze/load", pre + "_analyze(); " + pre + "_loadsolution()");
    t.ok(pre + " analyse/load_solution", pre + "_analyse(); " + pre + "_load_solution()");
    t.ok(post + " point values", post + "_getpointvalues(5,2.5); " + post + "_get_point_values(5,2.5)");
    t.ok(post + " counts", post + "_numnodes(); " + post + "_num_nodes(); " +
                         post + "_numelements(); " + post + "_num_elements()");
    t.ok(post + " node/element", post + "_getnode(1); " + post + "_get_node(1); " +
                              post + "_getelement(1); " + post + "_get_element(1)");
    t.ok(post + " contour/integrals",
         post + "_clearcontour(); " + post + "_addcontour(5,0); " + post + "_add_contour(5,5); " +
         post + "_lineintegral(0); " + post + "_line_integral(0); " +
         post + "_clear_contour(); " + post + "_addcontour(5,0); " + post + "_addcontour(5,5); " +
         post + "_selectblock(5,2.5); " + post + "_select_block(5,2.5); " +
         post + "_blockintegral(0); " + post + "_block_integral(0); " +
         post + "_clearblock(); " + post + "_clear_block(); " +
         post + "_groupselectblock(0); " + post + "_group_select_block(0)");
    run_many(t, post + " view noops",
             {post + "_smooth", post + "_showdensityplot", post + "_show_density_plot",
              post + "_hidedensityplot", post + "_hide_density_plot",
              post + "_showcontourplot", post + "_show_contour_plot",
              post + "_hidecontourplot", post + "_hide_contour_plot",
              post + "_showvectorplot", post + "_show_vector_plot",
              post + "_hidevectorplot", post + "_hide_vector_plot",
              post + "_showpoints", post + "_show_points", post + "_hidepoints",
              post + "_hide_points", post + "_showmesh", post + "_show_mesh",
              post + "_hidemesh", post + "_hide_mesh", post + "_shownames",
              post + "_show_names", post + "_showgrid", post + "_show_grid",
              post + "_hidegrid", post + "_hide_grid", post + "_refreshview",
              post + "_refrescview", post + "_refresh_view", post + "_reload",
              post + "_zoomnatural", post + "_zoom_natural", post + "_zoomout",
              post + "_zoom_out", post + "_zoomin", post + "_zoom_in", post + "_zoom",
              post + "_seteditmode", post + "_set_edit_mode", post + "_setgrid",
              post + "_set_grid", post + "_setfocus", post + "_set_focus",
              post + "_maximize", post + "_minimize", post + "_resize",
              post + "_restore", post + "_close", post + "_gridsnap", post + "_grid_snap"}, "1");
}

void test_unsupported(LuaTest& t) {
    const std::vector<std::string> names = {
        "actxprint", "lua2matlab", "flput", "makeplot", "mlopen", "mlclose", "mlput",
        "mi_savebitmap", "mi_save_bitmap", "mi_savedxf", "mi_save_dxf", "mi_savemetafile",
        "mi_save_metafile", "mi_readdxf", "mi_read_dxf", "mi_modifymaterial",
        "mi_modify_material", "mi_modifycircprop", "mi_modify_circ_prop",
        "ei_savebitmap", "ei_readdxf", "hi_addtkpoint", "hi_clear_tk_points",
        "ci_defineouterspace", "ci_attachdefault", "mo_gapintegral", "mo_getgapa",
        "mo_gradient", "mo_makeplot", "eo_getconductorproperties", "ho_make_plot",
        "co_savebitmap"
    };
    for (const auto& name : names) {
        t.lua_error_contains("unsupported:" + name, call(name), name + " is not supported");
    }
}

} // namespace

int main(int argc, char** argv) {
    if (argc == 2 && std::strcmp(argv[1], "--list") == 0) {
        for (size_t i = 0; i < femm_lua_num_commands(); ++i) {
            std::cout << femm_lua_command_name(i) << "\n";
        }
        return 0;
    }

    test_registry();
    LuaTest t;
    test_globals(t);
    test_preprocessor_aliases(t, "mi", 0);
    test_preprocessor_aliases(t, "ei", 1);
    test_preprocessor_aliases(t, "hi", 2);
    test_preprocessor_aliases(t, "ci", 3);
    test_open_roundtrip(t);
    test_solve_and_post(t, "mi", "mo", 0);
    test_solve_and_post(t, "ei", "eo", 1);
    test_solve_and_post(t, "hi", "ho", 2);
    test_solve_and_post(t, "ci", "co", 3);
    test_unsupported(t);

    std::cout << "Lua compatibility conformance passed: " << t.passed
              << " eval groups, " << femm_lua_num_commands()
              << " commands registered\n";
    return 0;
}
