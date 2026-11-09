def pr($n; $state; $base; $body; $head):
  {number: $n, url: "https://github.com/example/repo/pull/\($n)", state: $state, headRefName: $head, baseRefName: $base,
   headRefOid: ("\($n)" + "0" * 37)[0:40], mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", statusCheckRollup: [],
   body: $body, labels: [{id: "LA_aa", name: "agent-authored", description: "", color: "EDEDED"}], comments: [], reviews: [],
   author: {id: "U_1", is_bot: false, login: "shim-user", name: "Shim"}, closingIssuesReferences: [], autoMergeRequest: null,
   mergedAt: (if $state == "MERGED" then "2026-06-01T00:00:00Z" else null end)};
