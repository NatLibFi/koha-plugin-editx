[% WRAPPER 'sub-header.inc' %]
    [% WRAPPER breadcrumbs %]
        [% WRAPPER breadcrumb_item %]
            <a href="/cgi-bin/koha/plugins/plugins-home.pl?method=tool">Plugins</a>
        [% END %]
        [% WRAPPER breadcrumb_item %]
            <a href="[% tool_href | html %]">EDItX plugin</a>
            [% IF active_method != 'configure' && configure_href %]
                (<a href="[% configure_href | html %]">Configure</a>)
            [% END %]
        [% END %]
        [% WRAPPER breadcrumb_item bc_active= 1 %]
            <span>[% active_text | html %]</span>
        [% END %]
    [% END #/ WRAPPER breadcrumbs %]
[% END #/ WRAPPER sub-header.inc %]
