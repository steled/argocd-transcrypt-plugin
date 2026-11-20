/**
 * Commitlint configuration
 * 
 * Enforces conventional commits format:
 * type(scope): subject
 * 
 * Examples:
 *   feat(docker): add support for custom cipher
 *   fix(hook): handle missing password gracefully
 *   docs(readme): update installation steps
 *   chore(deps): bump argocd to v2.11.0
 */

module.exports = {
  extends: ['@commitlint/config-conventional'],
  // Ignore Renovate commits that start with "Update"
  ignores: [
    (message) => message.includes('Update') && message.match(/^(feat|fix|chore)\(deps\):/),
  ],
  rules: {
    // Type enum: allowed commit types
    'type-enum': [
      2,
      'always',
      [
        'feat',     // New feature
        'fix',      // Bug fix
        'docs',     // Documentation only
        'style',    // Formatting, missing semicolons, etc
        'refactor', // Code change that neither fixes a bug nor adds a feature
        'perf',     // Performance improvement
        'test',     // Adding or updating tests
        'chore',    // Maintenance tasks, dependency updates
        'ci',       // CI/CD changes
        'build',    // Build system or external dependencies
        'revert',   // Revert previous commit
      ],
    ],
    
    // Subject case: enforce lowercase (except for Renovate commits)
    'subject-case': [
      2,
      'always',
      'lower-case',
    ],
    
    // Subject length: max 100 characters
    'subject-max-length': [2, 'always', 100],
    
    // Subject empty: must not be empty
    'subject-empty': [2, 'never'],
    
    // Body leading blank: require blank line before body
    'body-leading-blank': [2, 'always'],
    
    // Footer leading blank: require blank line before footer
    'footer-leading-blank': [2, 'always'],
    
    // Scope: optional but recommended
    'scope-empty': [0, 'never'],
    
    // Scope enum: allowed scopes (optional, comment out if too restrictive)
    'scope-enum': [
      1,
      'always',
      [
        'docker',      // Docker image and Dockerfile changes
        'hook',        // Post-checkout hook changes
        'k8s',         // Kubernetes manifests
        'docs',        // Documentation files
        'tests',       // Test files
        'ci',          // CI/CD workflows
        'deps',        // Dependency updates
        'security',    // Security-related changes
        'examples',    // Example configurations
      ],
    ],
  },
};
